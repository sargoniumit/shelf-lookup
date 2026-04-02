import 'package:shared_preferences/shared_preferences.dart';

class UsageService {
  static const _maxFreeScans = 10;
  static const _remainingScansKey = 'remaining_scans';
  static const _isPremiumKey = 'is_premium';

  String? _lastScannedContent;

  Future<int> getRemainingScans() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_remainingScansKey) ?? _maxFreeScans;
  }

  Future<void> decrementScanCount(String currentText) async {
    final trimmed = currentText.trim();
    if (trimmed == _lastScannedContent) return;
    if (await isPremium()) return;
    final prefs = await SharedPreferences.getInstance();
    final remaining = prefs.getInt(_remainingScansKey) ?? _maxFreeScans;
    if (remaining > 0) {
      await prefs.setInt(_remainingScansKey, remaining - 1);
    }
    _lastScannedContent = trimmed;
  }

  Future<bool> isPremium() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_isPremiumKey) ?? false;
  }

  Future<void> setPremium(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_isPremiumKey, value);
  }
}
