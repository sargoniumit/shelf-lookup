import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../services/usage_service.dart';

const _neonGreen = Color(0xFF00E676);
const _glassWhite = Color(0x4DFFFFFF);
const _glassBorder = Color(0x33FFFFFF);
const _productId = 'spottext_full_unlock';

class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key});

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  final InAppPurchase _iap = InAppPurchase.instance;
  final UsageService _usageService = UsageService();
  StreamSubscription<List<PurchaseDetails>>? _subscription;
  bool _isRestoring = false;
  bool _restoredFound = false;
  bool _isLoading = false;
  bool _isStoreAvailable = false;
  bool _isLoadingStore = true;

  @override
  void initState() {
    super.initState();
    _subscription = _iap.purchaseStream.listen(
      _onPurchaseUpdated,
      onDone: () => _subscription?.cancel(),
      onError: (error) => debugPrint('Purchase stream error: $error'),
    );
    _checkStoreAvailability();
  }

  Future<void> _checkStoreAvailability() async {
    final available = await _iap.isAvailable();
    if (mounted) {
      setState(() {
        _isStoreAvailable = available;
        _isLoadingStore = false;
      });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _onPurchaseUpdated(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.productID == _productId) {
        switch (purchase.status) {
          case PurchaseStatus.purchased:
          case PurchaseStatus.restored:
            _restoredFound = true;

            if (purchase.pendingCompletePurchase) {
              await _iap.completePurchase(purchase);
            }

            await _usageService.setPremium(true);

            if (mounted) {
              setState(() {
                _isRestoring = false;
                _isLoading = false;
              });

              final msg = purchase.status == PurchaseStatus.restored
                  ? 'Kupovina uspešno vraćena! Uživajte u SpotText-u.'
                  : 'Uspeh! SpotText Unlimited je aktiviran.';

              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(msg),
                  backgroundColor: _neonGreen,
                ),
              );
              Navigator.pop(context, true);
            }
            return;

          case PurchaseStatus.error:
            if (mounted) {
              setState(() {
                _isRestoring = false;
                _isLoading = false;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                      'Došlo je do greške. Pokušajte ponovo.'),
                  backgroundColor: Colors.redAccent,
                ),
              );
            }
            break;

          case PurchaseStatus.canceled:
            if (mounted) {
              setState(() => _isLoading = false);
            }
            break;

          case PurchaseStatus.pending:
            break;
        }
      }
    }

    // Stream delivered updates but no matching product was found (restore only)
    if (_isRestoring && !_restoredFound) {
      await Future.delayed(const Duration(seconds: 2));
      if (_isRestoring && !_restoredFound && mounted) {
        setState(() => _isRestoring = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Nismo pronašli prethodne kupovine za ovaj nalog.'),
          ),
        );
      }
    }
  }

  Future<void> _buyProduct() async {
    setState(() => _isLoading = true);

    if (!_isStoreAvailable) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Prodavnica trenutno nije dostupna. Proverite internet konekciju.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    final response = await _iap.queryProductDetails({_productId});
    if (response.productDetails.isEmpty) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Proizvod nije pronađen u prodavnici.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    final product = response.productDetails.first;
    final purchaseParam = PurchaseParam(productDetails: product);
    await _iap.buyNonConsumable(purchaseParam: purchaseParam);
  }

  Future<void> _restorePurchases() async {
    setState(() {
      _isRestoring = true;
      _restoredFound = false;
    });
    await _iap.restorePurchases();
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ---- Dark blurred backdrop ----
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(color: const Color(0xCC000000)),
          ),

          // ---- Content ----
          SafeArea(
            child: Column(
              children: [
                // Close button
                Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8, right: 12),
                    child: IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close,
                          color: Colors.white.withValues(alpha: 0.5),
                          size: 26),
                    ),
                  ),
                ),

                const Spacer(flex: 2),

                // ---- App icon ----
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _glassWhite,
                    border: Border.all(color: _glassBorder, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: _neonGreen.withValues(alpha: 0.25),
                        blurRadius: 24,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.document_scanner_outlined,
                      color: _neonGreen, size: 40),
                ),

                const SizedBox(height: 24),

                // ---- Title ----
                const Text(
                  'Unlock Unlimited\nSpotting',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),

                const SizedBox(height: 8),

                Text(
                  'One purchase. Yours forever.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 14,
                  ),
                ),

                const SizedBox(height: 36),

                // ---- Benefits list ----
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 20),
                        decoration: BoxDecoration(
                          color: _glassWhite,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: _glassBorder),
                        ),
                        child: Column(
                          children: [
                            _BenefitRow(text: 'Unlimited Scans'),
                            const SizedBox(height: 14),
                            _BenefitRow(text: 'Priority Support'),
                            const SizedBox(height: 14),
                            _BenefitRow(
                                text:
                                    'One-time Payment (No Subscriptions)'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                const Spacer(flex: 3),

                // ---- Store connection status ----
                if (_isLoadingStore)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Colors.white38,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Connecting to Google Play Store...',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),

                // ---- Purchase button ----
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: (_isLoading || _isLoadingStore)
                          ? null
                          : _buyProduct,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _neonGreen,
                        foregroundColor: Colors.black,
                        disabledBackgroundColor:
                            _neonGreen.withValues(alpha: 0.4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                        elevation: 0,
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.black54,
                              ),
                            )
                          : const Text(
                              'Get Lifetime Access — \$2.99',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                ),

                const SizedBox(height: 14),

                // ---- Restore purchase ----
                _isRestoring
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white54,
                          ),
                        ),
                      )
                    : TextButton(
                        onPressed: _restorePurchases,
                        child: Text(
                          'Restore Purchase',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),

                SizedBox(height: pad.bottom + 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BenefitRow extends StatelessWidget {
  final String text;
  const _BenefitRow({required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _neonGreen.withValues(alpha: 0.15),
          ),
          child: const Icon(Icons.check, color: _neonGreen, size: 16),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
