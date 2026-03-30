import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';

// Fraction of the frame sent to ML Kit (centre region).
const _cropFraction = 0.65;

class ScannerScreen extends StatefulWidget {
  final String searchWord;
  const ScannerScreen({super.key, required this.searchWord});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  CameraController? _cameraController;
  late final TextRecognizer _textRecognizer;
  bool _isProcessing = false;
  bool _isDisposed = false;
  int _lastProcessedTimestamp = 0;
  static const _frameIntervalMs = 150;
  List<Rect> _displayRects = [];
  Size? _displayImageSize;
  Timer? _persistTimer;

  // Rolling window of recent frame results: true = any text detected, false = none
  final List<bool> _recentFrameResults = [];
  static const _rollingWindowSize = 12;
  _ScanQuality _scanQuality = _ScanQuality.initializing;

  @override
  void initState() {
    super.initState();
    _textRecognizer = TextRecognizer();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera permission denied')),
        );
        Navigator.pop(context);
      }
      return;
    }

    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    _cameraController = CameraController(
      cameras.first,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );

    await _cameraController!.initialize();
    if (!mounted) return;

    // 2.5x zoom so small text is legible from ~2 m away
    try {
      final maxZoom = await _cameraController!.getMaxZoomLevel();
      final targetZoom = 3.0.clamp(1.0, maxZoom);
      await _cameraController!.setZoomLevel(targetZoom);
    } catch (e) {
      debugPrint('Zoom not supported: $e');
    }

    // Continuous auto-focus so moving the camera doesn't blur frames
    try {
      await _cameraController!.setFocusMode(FocusMode.auto);
    } catch (e) {
      debugPrint('Focus control not supported: $e');
    }

    setState(() {});
    await _cameraController!.startImageStream(_processImage);
  }

  Future<void> _processImage(CameraImage image) async {
    if (_isProcessing || _isDisposed) return;
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

      final needle = widget.searchWord.toLowerCase();
      final rects = <Rect>[];

      for (final block in result.blocks) {
        for (final line in block.lines) {
          for (final element in line.elements) {
            if (element.text.toLowerCase().contains(needle)) {
              // Shift from cropped-image coords to full-image coords
              rects.add(element.boundingBox.shift(crop.rotatedOffset));
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
          setState(() {
            _displayRects = rects;
            _displayImageSize = fullSize;
          });
        } else if (_displayRects.isNotEmpty && _persistTimer == null) {
          // Keep _displayRects visible for 1 second after last detection
          _persistTimer = Timer(const Duration(seconds: 1), () {
            if (mounted && !_isDisposed) {
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

    // Rotation
    final sensorOrientation = camera.sensorOrientation;
    final InputImageRotation rotation;
    if (camera.lensDirection == CameraLensDirection.front) {
      rotation = InputImageRotationValue.fromRawValue(
            (sensorOrientation + 360) % 360,
          ) ??
          InputImageRotation.rotation0deg;
    } else {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation) ??
          InputImageRotation.rotation0deg;
    }

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
    if (sensorOrientation == 90 || sensorOrientation == 270) {
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

    return _CropResult(inputImage: inputImage, rotatedOffset: rotatedOffset);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _persistTimer?.cancel();
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
        label = 'No text detected — point at a shelf';
        bg = Colors.blueGrey.shade700;
      case _ScanQuality.initializing:
        return const SizedBox.shrink();
    }

    return Container(
      key: ValueKey(_scanQuality),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: bg.withOpacity(0.85),
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

  @override
  Widget build(BuildContext context) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return Scaffold(
        appBar: AppBar(title: const Text('Scanning...')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text('Looking for "${widget.searchWord}"')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            fit: StackFit.expand,
            children: [
              CameraPreview(controller),
              // Scanning guide: dims area outside the centre crop window
              CustomPaint(
                painter: _ScanGuidePainter(cropFraction: _cropFraction),
              ),
              // Dynamic speed indicator
              if (_scanQuality != _ScanQuality.initializing)
                Positioned(
                  top: 12,
                  left: 16,
                  right: 16,
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: _buildSpeedBanner(),
                    ),
                  ),
                ),
              if (_displayImageSize != null && _displayRects.isNotEmpty)
                CustomPaint(
                  painter: _HighlightPainter(
                    matchRects: _displayRects,
                    imageSize: _displayImageSize!,
                    sensorOrientation:
                        controller.description.sensorOrientation,
                  ),
                ),
              if (_displayRects.isNotEmpty)
                Positioned(
                  bottom: 32,
                  left: 16,
                  right: 16,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green.shade700,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Text(
                        'Found "${widget.searchWord}"!',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
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
  const _CropResult({required this.inputImage, required this.rotatedOffset});
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
    final guideW = size.width * cropFraction;
    final guideH = size.height * cropFraction;
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
// Painter: green bounding boxes on matched text
// ---------------------------------------------------------------------------
class _HighlightPainter extends CustomPainter {
  final List<Rect> matchRects;
  final Size imageSize;
  final int sensorOrientation;

  _HighlightPainter({
    required this.matchRects,
    required this.imageSize,
    required this.sensorOrientation,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (matchRects.isEmpty) return;

    final fillPaint = Paint()
      ..color = const Color(0x4400E676)
      ..style = PaintingStyle.fill;

    final strokePaint = Paint()
      ..color = const Color(0xFF00E676)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    // ML Kit returns bounding boxes in the rotated (upright) coordinate space.
    // Most Android rear cameras have sensorOrientation == 90.
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
      final rrect = RRect.fromRectAndRadius(scaled, const Radius.circular(4));
      canvas.drawRRect(rrect, fillPaint);
      canvas.drawRRect(rrect, strokePaint);
    }
  }

  @override
  bool shouldRepaint(_HighlightPainter oldDelegate) =>
      oldDelegate.matchRects != matchRects;
}
