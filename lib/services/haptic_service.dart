import 'package:flutter/services.dart';

/// Haptic feedback servisi — uygulamada tutarlı dokunsal geri bildirim.
class HapticService {
  HapticService._();
  static final HapticService instance = HapticService._();

  /// Hafif dokunma (buton basma, toggle)
  void light() => HapticFeedback.lightImpact();

  /// Orta dokunma (onay, seçim)
  void medium() => HapticFeedback.mediumImpact();

  /// Ağır dokunma (hata, silme, önemli işlem)
  void heavy() => HapticFeedback.heavyImpact();

  /// Seçim değişimi (slider, stepper)
  void selection() => HapticFeedback.selectionClick();

  /// Başarı geri bildirimi
  void success() {
    HapticFeedback.lightImpact();
    Future.delayed(const Duration(milliseconds: 50), () => HapticFeedback.lightImpact());
  }

  /// Hata/Uyarı geri bildirimi
  void warning() {
    HapticFeedback.heavyImpact();
    Future.delayed(const Duration(milliseconds: 100), () => HapticFeedback.heavyImpact());
  }
}
