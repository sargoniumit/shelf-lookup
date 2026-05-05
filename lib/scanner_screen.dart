import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/paywall_screen.dart';
import 'services/stt_service.dart';
import 'services/usage_service.dart';

// Fraction of the frame sent to ML Kit (centre region).
// Smaller = tighter internal crop = text appears larger to OCR.
const _cropFraction = 0.40;

const _neonGreen = Color(0xFF00E676);
const _glassWhite = Color(0x4DFFFFFF);
const _glassBorder = Color(0x33FFFFFF);

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen>
    with SingleTickerProviderStateMixin {
  CameraController? _cameraController;
  late final TextRecognizer _textRecognizer;
  final _searchCtl = TextEditingController();
  final _searchFocusNode = FocusNode();
  bool _cameraReady = false;
  final List<String> _recentSearches = [];
  bool _isProcessing = false;
  bool _isDisposed = false;
  int _lastProcessedTimestamp = 0;
  static const _frameIntervalMs = 150;
  List<Rect> _displayRects = [];
  Size? _displayImageSize;
  Timer? _persistTimer;
  bool _isScanning = false;
  bool _flashOn = false;
  final _usageService = UsageService();
  final _sttService = SttService();
  int _remainingScans = 20;
  bool _isPremiumUser = false;
  bool _isListening = false;
  bool _isBuyingFromHome = false;
  bool _hasActiveMatch = false;
  bool _isLandscapeMode = false;
  int _effectiveRotation = 0;
  StreamSubscription<List<PurchaseDetails>>? _iapSubscription;
  static const _productId = 'spottext_full_unlock';

  // Rolling window of recent frame results: true = any text detected, false = none
  final List<bool> _recentFrameResults = [];
  static const _rollingWindowSize = 12;
  _ScanQuality _scanQuality = _ScanQuality.initializing;

  late final AnimationController _pulseCtl;
  static const _prefsKey = 'recent_searches';

  @override
  void initState() {
    super.initState();
    _textRecognizer = TextRecognizer();
    _pulseCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _searchFocusNode.addListener(() => setState(() {}));
    _loadRecentSearches();
    _loadUsageInfo();
    _iapSubscription = InAppPurchase.instance.purchaseStream.listen(
      _onHomePurchaseUpdated,
      onDone: () => _iapSubscription?.cancel(),
      onError: (error) => debugPrint('IAP stream error: $error'),
    );
  }

  Future<void> _loadRecentSearches() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_prefsKey);
    if (saved != null && mounted) {
      setState(() => _recentSearches.addAll(saved));
    }
  }

  Future<void> _loadUsageInfo() async {
    final remaining = await _usageService.getRemainingScans();
    final premium = await _usageService.isPremium();
    if (mounted) {
      setState(() {
        _remainingScans = remaining;
        _isPremiumUser = premium;
      });
    }
  }

  Future<void> _saveRecentSearches() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, _recentSearches);
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera permission denied')),
        );
      }
      return;
    }

    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    _cameraController = CameraController(
      cameras.first,
      ResolutionPreset.max,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );

    await _cameraController!.initialize();
    if (!mounted) return;

    // Optical/digital zoom for ~1 m reading distance
    try {
      final maxZoom = await _cameraController!.getMaxZoomLevel();
      final targetZoom = 2.0.clamp(1.0, maxZoom);
      await _cameraController!.setZoomLevel(targetZoom);
      debugPrint('Zoom set to $targetZoom (max: $maxZoom)');
    } catch (e) {
      debugPrint('Zoom not supported: $e');
    }

    // Continuous auto-focus so moving the camera doesn't blur frames
    try {
      await _cameraController!.setFocusMode(FocusMode.auto);
    } catch (e) {
      debugPrint('Focus control not supported: $e');
    }

    if (!mounted) return;
    setState(() => _cameraReady = true);
    await _cameraController!.startImageStream(_processImage);
  }

  Future<void> _processImage(CameraImage image) async {
    if (_isProcessing || _isDisposed || !_isScanning) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastProcessedTimestamp < _frameIntervalMs) return;
    _isProcessing = true;
    _lastProcessedTimestamp = now;

    try {
      final crop = _buildCroppedInputImage(image);
      if (crop == null) {
        _isProcessing = false;
        return;
      }

      final result = await _textRecognizer.processImage(crop.inputImage);
      final anyTextDetected = result.blocks.isNotEmpty;
      _updateScanQuality(anyTextDetected);

      final words = _searchCtl.text
          .trim()
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((w) => w.length >= 2)
          .toList();
      final rects = <Rect>[];
      final matchedTexts = <String>[];

      for (final block in result.blocks) {
        for (final line in block.lines) {
          for (final element in line.elements) {
            final elLower = element.text.toLowerCase();
            if (words.any((w) => elLower.contains(w))) {
              // Shift from cropped-image coords to full-image coords
              rects.add(element.boundingBox.shift(crop.rotatedOffset));
              matchedTexts.add(element.text);
            }
          }
        }
      }

      final fullSize =
          Size(image.width.toDouble(), image.height.toDouble());

      if (mounted && !_isDisposed) {
        if (rects.isNotEmpty) {
          _persistTimer?.cancel();
          _persistTimer = null;
          if (!_hasActiveMatch) {
            _hasActiveMatch = true;
            await _usageService.decrementScanCount(matchedTexts.join(' '));
            await _loadUsageInfo();
            if (_remainingScans <= 0 && !_isPremiumUser) {
              _stopAndShowPaywall();
              return;
            }
          }
          setState(() {
            _displayRects = rects;
            _displayImageSize = fullSize;
            _effectiveRotation = crop.adjustedRotation;
          });
        } else if (_displayRects.isNotEmpty && _persistTimer == null) {
          // Keep _displayRects visible for 1 second after last detection
          _persistTimer = Timer(const Duration(seconds: 1), () {
            if (mounted && !_isDisposed) {
              _hasActiveMatch = false;
              setState(() {
                _displayRects = [];
                _displayImageSize = null;
              });
            }
            _persistTimer = null;
          });
        }
      }
    } catch (e) {
      debugPrint('ML Kit error: $e');
    }

    _isProcessing = false;
  }

  void _updateScanQuality(bool anyTextDetected) {
    _recentFrameResults.add(anyTextDetected);
    if (_recentFrameResults.length > _rollingWindowSize) {
      _recentFrameResults.removeAt(0);
    }
    if (_recentFrameResults.length < 4) return; // need a few frames first

    final hits = _recentFrameResults.where((r) => r).length;
    final ratio = hits / _recentFrameResults.length;

    final _ScanQuality newQuality;
    if (ratio >= 0.5) {
      newQuality = _ScanQuality.good;
    } else if (ratio >= 0.2) {
      newQuality = _ScanQuality.tooFast;
    } else {
      newQuality = _ScanQuality.noText;
    }

    if (newQuality != _scanQuality && mounted && !_isDisposed) {
      setState(() => _scanQuality = newQuality);
    }
  }

  // ---------------------------------------------------------------------------
  // Crop the centre _cropFraction of the NV21 frame and build an InputImage.
  // Returns null when conversion fails.
  // ---------------------------------------------------------------------------
  _CropResult? _buildCroppedInputImage(CameraImage image) {
    final camera = _cameraController?.description;
    if (camera == null) return null;

    // Rotation – adjust for device orientation so ML Kit boxes match preview
    final sensorOrientation = camera.sensorOrientation;
    final adjustedDeg = _isLandscapeMode
        ? (sensorOrientation + 270) % 360 // subtract 90° for landscape
        : sensorOrientation;
    final rotation = InputImageRotationValue.fromRawValue(adjustedDeg) ??
        InputImageRotation.rotation0deg;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;
    if (image.planes.isEmpty) return null;

    final w = image.width;
    final h = image.height;

    // Centre crop dimensions (must be even for NV21)
    final cropW = ((w * _cropFraction).toInt()) & ~1;
    final cropH = ((h * _cropFraction).toInt()) & ~1;
    final cropX = ((w - cropW) ~/ 2) & ~1;
    final cropY = ((h - cropH) ~/ 2) & ~1;

    final yPlane = image.planes[0];
    final yStride = yPlane.bytesPerRow;
    final outSize = cropW * cropH * 3 ~/ 2;
    final out = Uint8List(outSize);
    var dst = 0;

    // ---- Y rows ----
    for (var r = cropY; r < cropY + cropH; r++) {
      final src = r * yStride + cropX;
      if (src + cropW > yPlane.bytes.length) break;
      out.setRange(dst, dst + cropW, yPlane.bytes, src);
      dst += cropW;
    }

    // ---- VU rows (NV21: planes[1] is interleaved V-U with same row stride) ----
    if (image.planes.length >= 2) {
      final vuPlane = image.planes[1];
      final vuStride = vuPlane.bytesPerRow;
      final vuCropY = cropY ~/ 2;
      final vuCropH = cropH ~/ 2;
      for (var r = vuCropY; r < vuCropY + vuCropH; r++) {
        final src = r * vuStride + cropX;
        if (src + cropW > vuPlane.bytes.length) break;
        out.setRange(dst, dst + cropW, vuPlane.bytes, src);
        dst += cropW;
      }
    } else {
      // No UV data available – fill with neutral grey
      for (var i = dst; i < outSize; i++) {
        out[i] = 0x80;
      }
    }

    // Offset to map ML Kit boxes (rotated-crop coords) → full rotated-image coords.
    // A centred crop stays centred after rotation.
    final Offset rotatedOffset;
    if (adjustedDeg == 90 || adjustedDeg == 270) {
      rotatedOffset = Offset((h - cropH) / 2.0, (w - cropW) / 2.0);
    } else {
      rotatedOffset = Offset((w - cropW) / 2.0, (h - cropH) / 2.0);
    }

    final inputImage = InputImage.fromBytes(
      bytes: out,
      metadata: InputImageMetadata(
        size: Size(cropW.toDouble(), cropH.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: cropW,
      ),
    );

    return _CropResult(
      inputImage: inputImage,
      rotatedOffset: rotatedOffset,
      adjustedRotation: adjustedDeg,
    );
  }

  void _stopAndShowPaywall() {
    setState(() {
      _isScanning = false;
      _displayRects = [];
      _displayImageSize = null;
      _scanQuality = _ScanQuality.initializing;
      _recentFrameResults.clear();
    });
    _showPaywall();
  }

  Future<void> _showPaywall() async {
    await Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (context, animation, secondaryAnimation) => const PaywallScreen(),
        transitionsBuilder: (context, anim, secondaryAnimation, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
    _loadUsageInfo();
  }

  void _goBackToWelcome() {
    _cameraController?.stopImageStream().catchError((_) {});
    _cameraController?.dispose();
    _cameraController = null;
    setState(() {
      _cameraReady = false;
      _isScanning = false;
      _flashOn = false;
      _displayRects = [];
      _displayImageSize = null;
      _scanQuality = _ScanQuality.initializing;
      _recentFrameResults.clear();
    });
  }

  Future<void> _toggleFlash() async {
    if (_cameraController == null) return;
    try {
      _flashOn = !_flashOn;
      await _cameraController!.setFlashMode(
        _flashOn ? FlashMode.torch : FlashMode.off,
      );
      setState(() {});
    } catch (e) {
      debugPrint('Flash error: $e');
    }
  }

  void _toggleScanning() {
    if (_isScanning) {
      setState(() {
        _isScanning = false;
        _displayRects = [];
        _displayImageSize = null;
        _scanQuality = _ScanQuality.initializing;
        _recentFrameResults.clear();
      });
    } else {
      _startScan();
    }
  }

  Future<void> _toggleVoiceInput() async {
    if (_isListening) {
      await _sttService.stopListening();
      setState(() => _isListening = false);
      if (_searchCtl.text.trim().isNotEmpty) {
        _startScan();
      }
      return;
    }

    final started = await _sttService.startListening((text) {
      if (!mounted) return;
      setState(() {
        _searchCtl.text = text;
        _searchCtl.selection =
            TextSelection.collapsed(offset: text.length);
      });
    });

    if (started) {
      setState(() => _isListening = true);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Mikrofon nije dostupan. Proverite dozvole.'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _startScan() async {
    final term = _searchCtl.text.trim();
    if (term.isEmpty) return;

    // Check scan budget before starting
    final remaining = await _usageService.getRemainingScans();
    if (remaining <= 0 && !(await _usageService.isPremium())) {
      _showPaywall();
      return;
    }

    // Save to recent searches
    _recentSearches.remove(term);
    _recentSearches.insert(0, term);
    if (_recentSearches.length > 10) _recentSearches.removeLast();
    _saveRecentSearches();

    _searchFocusNode.unfocus();

    if (!_cameraReady) {
      await _initCamera();
    }
    if (!mounted || !_cameraReady) return;
    setState(() => _isScanning = true);
  }

  Future<void> _buyProductFromHome() async {
    setState(() => _isBuyingFromHome = true);

    final iap = InAppPurchase.instance;
    final available = await iap.isAvailable();
    if (!available) {
      if (mounted) {
        setState(() => _isBuyingFromHome = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Prodavnica trenutno nije dostupna.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    final response = await iap.queryProductDetails({_productId});
    if (response.productDetails.isEmpty) {
      if (mounted) {
        setState(() => _isBuyingFromHome = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Proizvod nije pronađen.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    final product = response.productDetails.first;
    try {
      await iap.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: product),
      );
    } catch (_) {
      // purchase dialog failed to open
    }
    if (mounted) setState(() => _isBuyingFromHome = false);
  }

  Future<void> _onHomePurchaseUpdated(
      List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.productID == _productId) {
        switch (purchase.status) {
          case PurchaseStatus.purchased:
          case PurchaseStatus.restored:
            if (purchase.pendingCompletePurchase) {
              await InAppPurchase.instance.completePurchase(purchase);
            }
            await _usageService.setPremium(true);
            await _loadUsageInfo();
            if (mounted) {
              setState(() => _isBuyingFromHome = false);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content:
                      Text('Uspeh! SpotText Unlimited je aktiviran.'),
                  backgroundColor: _neonGreen,
                ),
              );
            }
            break;
          case PurchaseStatus.error:
            if (mounted) {
              setState(() => _isBuyingFromHome = false);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Došlo je do greške. Pokušajte ponovo.'),
                  backgroundColor: Colors.redAccent,
                ),
              );
            }
            break;
          case PurchaseStatus.canceled:
            if (mounted) setState(() => _isBuyingFromHome = false);
            break;
          case PurchaseStatus.pending:
            break;
        }
      }
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _pulseCtl.dispose();
    _searchFocusNode.dispose();
    _searchCtl.dispose();
    _persistTimer?.cancel();
    _sttService.dispose();
    _iapSubscription?.cancel();
    _cameraController?.stopImageStream().catchError((_) {});
    _cameraController?.dispose();
    _textRecognizer.close();
    super.dispose();
  }

  Widget _buildSpeedBanner() {
    final IconData icon;
    final String label;
    final Color bg;

    switch (_scanQuality) {
      case _ScanQuality.good:
        icon = Icons.check_circle_outline;
        label = 'Good speed — scanning';
        bg = Colors.green.shade700;
      case _ScanQuality.tooFast:
        icon = Icons.speed;
        label = 'Slow down for better results';
        bg = Colors.orange.shade800;
      case _ScanQuality.noText:
        icon = Icons.search_off;
        label = 'No text detected';
        bg = Colors.blueGrey.shade700;
      case _ScanQuality.initializing:
        return const SizedBox.shrink();
    }

    return Container(
      key: ValueKey(_scanQuality),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  void _showAboutInfo() {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _neonGreen.withValues(alpha: 0.15),
                ),
                child: const Icon(Icons.document_scanner_outlined,
                    color: _neonGreen, size: 32),
              ),
              const SizedBox(height: 16),
              const Text(
                'SpotText',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Version 1.0.0',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
              const SizedBox(height: 16),
              const Divider(color: Colors.white12),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.code,
                      color: Colors.white.withValues(alpha: 0.5), size: 18),
                  const SizedBox(width: 10),
                  const Text(
                    'Developer: SargoniumIT',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.email_outlined,
                      color: Colors.white.withValues(alpha: 0.5), size: 18),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'sargoniumit@gmail.com',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  'Close',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Build helpers ----

  Widget _buildTitle(EdgeInsets pad) {
    return Positioned(
      top: pad.top + 12,
      left: 0,
      right: 0,
      child: Center(
        child: Text(
          'SpotText',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 14,
            fontWeight: FontWeight.w300,
            letterSpacing: 2.0,
          ),
        ),
      ),
    );
  }

  Widget _buildSearchColumn({required bool showScanButton}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Search input
        ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              decoration: BoxDecoration(
                color: _glassWhite,
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: _glassBorder),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: TextField(
                controller: _searchCtl,
                focusNode: _searchFocusNode,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _startScan(),
                decoration: InputDecoration(
                  hintText: 'What are you looking for?',
                  hintStyle:
                      TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                  prefixIcon: Icon(Icons.search,
                      color: Colors.white.withValues(alpha: 0.7)),
                  suffixIcon: GestureDetector(
                    onTap: _toggleVoiceInput,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: _isListening
                          ? const _PulsingMic()
                          : Icon(Icons.mic_none,
                              color: Colors.white.withValues(alpha: 0.5)),
                    ),
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 16),
                ),
              ),
            ),
          ),
        ),

        // Recent searches dropdown
        if (_searchFocusNode.hasFocus && _recentSearches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(
                  decoration: BoxDecoration(
                    color: _glassWhite,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _glassBorder),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                        child: Row(
                          children: [
                            Icon(Icons.history,
                                color: Colors.white.withValues(alpha: 0.4),
                                size: 14),
                            const SizedBox(width: 6),
                            Text(
                              'Recent searches',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.4),
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ..._recentSearches.map((term) => InkWell(
                            onTap: () {
                              _searchCtl.text = term;
                              _searchCtl.selection = TextSelection.collapsed(
                                  offset: term.length);
                              _startScan();
                            },
                            child: Padding(
                              padding: const EdgeInsets.only(
                                  left: 16, top: 10, bottom: 10, right: 8),
                              child: Row(
                                children: [
                                  const Icon(Icons.search,
                                      color: Colors.white54, size: 18),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(term,
                                        style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 15),
                                        overflow: TextOverflow.ellipsis),
                                  ),
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      setState(() {
                                        _recentSearches.remove(term);
                                      });
                                      _saveRecentSearches();
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 12),
                                      child: Icon(Icons.close,
                                          color: Colors.white.withValues(alpha: 0.35),
                                          size: 18),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
              ),
            ),
          ),

        // Scan button (only in input mode)
        if (showScanButton)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _startScan,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _neonGreen,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26),
                  ),
                  elevation: 0,
                ),
                child: const Text('Scan',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
          ),

        // Promo text (only for non-premium users)
        if (showScanButton && !_isPremiumUser) ...[
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              'Enjoy your first 10 scans for free!\nUnlock lifetime unlimited access for just \$2.99',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: SizedBox(
              height: 40,
              child: OutlinedButton(
                onPressed: _isBuyingFromHome ? null : _buyProductFromHome,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                    color: _neonGreen.withValues(alpha: _isBuyingFromHome ? 0.3 : 0.6),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                child: _isBuyingFromHome
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _neonGreen,
                        ),
                      )
                    : const Text(
                        'Get Unlimited Access',
                        style: TextStyle(
                          color: _neonGreen,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSearchBar(EdgeInsets pad,
      {required bool showScanButton, bool isLandscape = false}) {
    final hPad = isLandscape
        ? MediaQuery.of(context).size.width * 0.08
        : 16.0;
    return Positioned(
      top: pad.top + (isLandscape ? 6 : 38),
      left: hPad,
      right: hPad,
      child: _buildSearchColumn(showScanButton: showScanButton),
    );
  }

  Widget _buildBottomBar(EdgeInsets pad, {bool isLandscape = false}) {
    final hPad = isLandscape
        ? MediaQuery.of(context).size.width * 0.25
        : 16.0;
    return Positioned(
      bottom: pad.bottom + (isLandscape ? 8 : 16),
      left: hPad,
      right: hPad,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _glassWhite,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: _glassBorder),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Flash toggle
                IconButton(
                  onPressed: _toggleFlash,
                  icon: Icon(
                    _flashOn ? Icons.flash_on : Icons.flash_off,
                    color: _flashOn ? _neonGreen : Colors.white70,
                    size: 26,
                  ),
                ),
                // Pulsing scan button
                ScaleTransition(
                  scale: _isScanning
                      ? Tween(begin: 1.0, end: 1.12)
                          .animate(CurvedAnimation(
                          parent: _pulseCtl,
                          curve: Curves.easeInOut,
                        ))
                      : const AlwaysStoppedAnimation(1.0),
                  child: GestureDetector(
                    onTap: _toggleScanning,
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isScanning
                            ? _neonGreen
                            : Colors.white.withValues(alpha: 0.15),
                        border: Border.all(
                          color: _isScanning
                              ? _neonGreen
                              : Colors.white54,
                          width: 3,
                        ),
                        boxShadow: _isScanning
                            ? [
                                BoxShadow(
                                  color: _neonGreen.withValues(alpha: 0.4),
                                  blurRadius: 18,
                                  spreadRadius: 2,
                                )
                              ]
                            : null,
                      ),
                      child: Center(
                        child: Text(
                          _isScanning ? 'Stop' : 'Scan',
                          style: TextStyle(
                            color: _isScanning ? Colors.black : Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Back to welcome
                IconButton(
                  onPressed: _goBackToWelcome,
                  icon: const Icon(Icons.arrow_back,
                      color: Colors.white70, size: 26),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    final mSize = MediaQuery.of(context).size;
    _isLandscapeMode = mSize.width > mSize.height;
    final controller = _cameraController;
    final cameraActive =
        controller != null && controller.value.isInitialized && _cameraReady;

    // ---------- Input-first mode (no camera yet) ----------
    if (!cameraActive) {
      final homeLandscape = _isLandscapeMode;
      final homeHPad = homeLandscape ? mSize.width * 0.15 : 16.0;

      return Scaffold(
        backgroundColor: const Color(0xFF121212),
        resizeToAvoidBottomInset: true,
        body: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(
                  top: pad.top + (homeLandscape ? 16 : 40),
                  bottom: pad.bottom + (homeLandscape ? 16 : 40),
                  left: homeHPad,
                  right: homeHPad,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'SpotText',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: homeLandscape ? 22 : 26,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.5,
                      ),
                    ),
                    SizedBox(height: homeLandscape ? 12 : 20),
                    _buildSearchColumn(showScanButton: true),
                  ],
                ),
              ),
            ),
            Positioned(
              top: pad.top + 8,
              right: homeLandscape ? pad.right + 8 : 8,
              child: IconButton(
                onPressed: _showAboutInfo,
                icon: Icon(Icons.info_outline,
                    color: Colors.white.withValues(alpha: 0.5), size: 24),
              ),
            ),
          ],
        ),
      );
    }

    // ---------- Camera scanning mode ----------
    final isLandscape = _isLandscapeMode;
    final hPad = isLandscape ? mSize.width * 0.08 : 16.0;

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ---- Camera background ----
          CameraPreview(controller),

          // ---- Scan-area guide (subtle dim) ----
          CustomPaint(
            painter: _ScanGuidePainter(cropFraction: _cropFraction),
          ),

          // ---- AR corner-bracket highlights ----
          if (_displayImageSize != null && _displayRects.isNotEmpty)
            CustomPaint(
              painter: _CornerBracketPainter(
                matchRects: _displayRects,
                imageSize: _displayImageSize!,
                sensorOrientation: _effectiveRotation,
              ),
            ),

          // ---- Title ----
          if (!isLandscape) _buildTitle(pad),

          // ---- Scan counter (top-right) ----
          if (!_isPremiumUser)
            Positioned(
              top: pad.top + (isLandscape ? 6 : 10),
              right: isLandscape ? pad.right + 12 : 16,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _glassWhite,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _glassBorder),
                    ),
                    child: Text(
                      'Free scans: $_remainingScans/10',
                      style: TextStyle(
                        color: _remainingScans < 5
                            ? Colors.orangeAccent
                            : Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // ---- Search bar (no Scan button in camera mode) ----
          _buildSearchBar(pad,
              showScanButton: false, isLandscape: isLandscape),

          // ---- Speed banner (below search bar) ----
          if (_isScanning && _scanQuality != _ScanQuality.initializing)
            Positioned(
              top: pad.top + (isLandscape ? 56 : 106),
              left: hPad,
              right: hPad,
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _buildSpeedBanner(),
                ),
              ),
            ),

          // ---- "Found" notification above bottom bar ----
          if (_displayRects.isNotEmpty)
            Positioned(
              bottom: pad.bottom + (isLandscape ? 80 : 110),
              left: hPad,
              right: hPad,
              child: Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      decoration: BoxDecoration(
                        color: _neonGreen.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                            color: _neonGreen.withValues(alpha: 0.6)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check_circle,
                              color: _neonGreen, size: 22),
                          const SizedBox(width: 10),
                          Text(
                            'Found "${_searchCtl.text.trim()}"!',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // ---- Glass bottom action bar ----
          _buildBottomBar(pad, isLandscape: isLandscape),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helper: holds the cropped InputImage + offset to map boxes back
// ---------------------------------------------------------------------------
class _CropResult {
  final InputImage inputImage;
  final Offset rotatedOffset;
  final int adjustedRotation;
  const _CropResult({
    required this.inputImage,
    required this.rotatedOffset,
    required this.adjustedRotation,
  });
}

enum _ScanQuality { initializing, good, tooFast, noText }

// ---------------------------------------------------------------------------
// Painter: dimmed overlay with a rounded centre "scan window" + corner accents
// ---------------------------------------------------------------------------
class _ScanGuidePainter extends CustomPainter {
  final double cropFraction;
  _ScanGuidePainter({required this.cropFraction});

  @override
  void paint(Canvas canvas, Size size) {
    final isLandscape = size.width > size.height;
    final guideW = isLandscape ? size.width * 0.80 : size.width * cropFraction;
    final guideH = isLandscape ? size.height * 0.30 : size.height * 0.45;
    final left = (size.width - guideW) / 2;
    final top = (size.height - guideH) / 2;
    final guideRect = Rect.fromLTWH(left, top, guideW, guideH);
    final guideRRect =
        RRect.fromRectAndRadius(guideRect, const Radius.circular(16));

    // Dim area outside the guide
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height)),
        Path()..addRRect(guideRRect),
      ),
      Paint()..color = const Color(0x66000000),
    );

    // Border
    canvas.drawRRect(
      guideRRect,
      Paint()
        ..color = Colors.white70
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Corner accents
    const cLen = 24.0;
    final ap = Paint()
      ..color = Colors.tealAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    // top-left
    canvas.drawLine(Offset(left, top + cLen), Offset(left, top), ap);
    canvas.drawLine(Offset(left, top), Offset(left + cLen, top), ap);
    // top-right
    canvas.drawLine(
        Offset(left + guideW - cLen, top), Offset(left + guideW, top), ap);
    canvas.drawLine(
        Offset(left + guideW, top), Offset(left + guideW, top + cLen), ap);
    // bottom-left
    canvas.drawLine(
        Offset(left, top + guideH - cLen), Offset(left, top + guideH), ap);
    canvas.drawLine(
        Offset(left, top + guideH), Offset(left + cLen, top + guideH), ap);
    // bottom-right
    canvas.drawLine(Offset(left + guideW, top + guideH - cLen),
        Offset(left + guideW, top + guideH), ap);
    canvas.drawLine(Offset(left + guideW - cLen, top + guideH),
        Offset(left + guideW, top + guideH), ap);
  }

  @override
  bool shouldRepaint(_ScanGuidePainter old) =>
      old.cropFraction != cropFraction;
}

// ---------------------------------------------------------------------------
// Painter: neon-green corner brackets on matched text
// ---------------------------------------------------------------------------
class _CornerBracketPainter extends CustomPainter {
  final List<Rect> matchRects;
  final Size imageSize;
  final int sensorOrientation;

  _CornerBracketPainter({
    required this.matchRects,
    required this.imageSize,
    required this.sensorOrientation,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (matchRects.isEmpty) return;

    final paint = Paint()
      ..color = _neonGreen
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    double rotatedW, rotatedH;
    if (sensorOrientation == 90 || sensorOrientation == 270) {
      rotatedW = imageSize.height;
      rotatedH = imageSize.width;
    } else {
      rotatedW = imageSize.width;
      rotatedH = imageSize.height;
    }

    final scaleX = size.width / rotatedW;
    final scaleY = size.height / rotatedH;

    for (final rect in matchRects) {
      final scaled = Rect.fromLTRB(
        rect.left * scaleX,
        rect.top * scaleY,
        rect.right * scaleX,
        rect.bottom * scaleY,
      );

      // Corner bracket length: ~20% of shorter side, capped at 18px
      final cLen = (scaled.shortestSide * 0.2).clamp(8.0, 18.0);
      final l = scaled.left, t = scaled.top;
      final r = scaled.right, b = scaled.bottom;

      // Top-left
      canvas.drawLine(Offset(l, t + cLen), Offset(l, t), paint);
      canvas.drawLine(Offset(l, t), Offset(l + cLen, t), paint);
      // Top-right
      canvas.drawLine(Offset(r - cLen, t), Offset(r, t), paint);
      canvas.drawLine(Offset(r, t), Offset(r, t + cLen), paint);
      // Bottom-left
      canvas.drawLine(Offset(l, b - cLen), Offset(l, b), paint);
      canvas.drawLine(Offset(l, b), Offset(l + cLen, b), paint);
      // Bottom-right
      canvas.drawLine(Offset(r, b - cLen), Offset(r, b), paint);
      canvas.drawLine(Offset(r - cLen, b), Offset(r, b), paint);
    }
  }

  @override
  bool shouldRepaint(_CornerBracketPainter oldDelegate) =>
      oldDelegate.matchRects != matchRects;
}

class _PulsingMic extends StatefulWidget {
  const _PulsingMic();

  @override
  State<_PulsingMic> createState() => _PulsingMicState();
}

class _PulsingMicState extends State<_PulsingMic>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.4, end: 1.0).animate(
        CurvedAnimation(parent: _ctl, curve: Curves.easeInOut),
      ),
      child: const Icon(Icons.mic, color: _neonGreen),
    );
  }
}
