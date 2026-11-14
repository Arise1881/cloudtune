import 'dart:async';

import 'package:flutter/foundation.dart';

import 'player_controller.dart';

/// Gizli onarım botu. Kullaniciyi asla rahatsiz etmez; arka planda
/// surekli tarar, Player'daki hatalari tespit eder ve otomatik onarir.
class RepairBot extends ChangeNotifier {
  RepairBot._();
  static final RepairBot instance = RepairBot._();

  Timer? _timer;
  bool _scanning = false;
  final List<String> _issues = [];

  bool get scanning => _timer?.isActive ?? false;
  List<String> get issues => List.unmodifiable(_issues);

  static void start() {
    if (instance._timer?.isActive ?? false) return;
    instance._timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (instance._scanning) return;
      instance._scanning = true;
      unawaited(instance._scan());
    });
  }

  static void stop() {
    instance._timer?.cancel();
    instance._timer = null;
  }

  Future<void> _scan() async {
    try {
      final player = PlayerController.instance;
      if (player.error != null && player.current != null) {
        // Hata var: onarim botu otomatik yeniden dener.
        player.retry();
      }
      if (player.loading && player.current == null) {
        // Kilitli yuklenme: Player zaten retry/timeout saati vardir.
      }
      _issues.clear();
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }
}
