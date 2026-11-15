import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'cloudflare.dart';
import 'player_controller.dart';

/// Gizli onarim botu. Kullaniciyi asla rahatsiz etmez, arayuzde hata
/// gostermez. Dusuk pil/CPU kullanimi icin uyarlanabilir araliklarla
/// calisir: sorun yokken seyrek, sorun varken sik tarar.
///
/// Onarim zinciri:
///   1) dogrudan YouTube akisini yeniden dene
///   2) Cloudflare aktarma kanali (yedek)
///   3) cihaz raporunu CloudTune@hotmail.com'a ileten onarim kaydi
class RepairBot extends ChangeNotifier with WidgetsBindingObserver {
  RepairBot._();
  static final RepairBot instance = RepairBot._();

  static const Duration _idleInterval = Duration(seconds: 30);
  static const Duration _busyInterval = Duration(seconds: 5);
  static const Duration _backgroundInterval = Duration(seconds: 90);

  Timer? _timer;
  bool _scanning = false;
  bool _foreground = true;
  bool _reported = false;
  int _consecutiveFailures = 0;
  int _fixCount = 0;
  DateTime? _lastFixAt;
  String? _lastIssue;

  /// Bot calisiyor mu (ayarlardaki gosterge icin).
  bool get active => _timer?.isActive ?? false;
  bool get scanning => _scanning;
  int get fixCount => _fixCount;
  DateTime? get lastFixAt => _lastFixAt;
  String? get lastIssue => _lastIssue;

  static Future<void> start() async {
    final bot = instance;
    if (bot._timer?.isActive ?? false) return;
    WidgetsBinding.instance.addObserver(bot);
    try {
      final info = await PackageInfo.fromPlatform();
      PlatformInfo.appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {}
    bot._schedule(bot._foreground ? _idleInterval : _backgroundInterval);
    bot.notifyListeners();
  }

  static void stop() {
    instance._timer?.cancel();
    instance._timer = null;
    WidgetsBinding.instance.removeObserver(instance);
    instance.notifyListeners();
  }

  void _schedule(Duration interval) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) {
      if (_scanning) return;
      _scanning = true;
      unawaited(_scan());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    // On planda enerji tasarrufu, arka planda daha seyrek tarama.
    _schedule(_foreground
        ? (_consecutiveFailures > 0 ? _busyInterval : _idleInterval)
        : _backgroundInterval);
    if (_foreground) {
      // On plana donuste hemen bir kontrol yap.
      if (!_scanning) {
        _scanning = true;
        unawaited(_scan());
      }
    }
  }

  Future<void> _scan() async {
    try {
      final player = PlayerController.instance;
      if (player.error != null && player.current != null) {
        _consecutiveFailures++;
        _lastIssue = player.error;
        await player.retry();
        _fixCount++;
        _lastFixAt = DateTime.now();
        _reported = false;
        // Sorun tekrar ediyorsa zincirin son halkasina gec.
        if (_consecutiveFailures >= 3 && !_reported) {
          _reported = true;
          unawaited(_escalate(player.current!.id, player.error!));
        }
      } else if (player.current != null) {
        if (_consecutiveFailures > 0) {
          _consecutiveFailures = 0;
          _schedule(_foreground ? _idleInterval : _backgroundInterval);
        }
      }
      if (_consecutiveFailures == 0 && _lastIssue != null) {
        _lastIssue = null;
      }
    } catch (_) {
      // Bot asla cokmez.
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  /// Cloudflare uzerinden onarim kaydi gonder; worker e-postayi
  /// CloudTune@hotmail.com'a iletir. Sessiz calisir.
  Future<void> _escalate(String videoId, String issue) async {
    final payload = CloudflareFallback.deviceInfo({
      'event_type': 'playback_unrecoverable',
      'video_id': videoId,
      'issue': issue,
      'fix_attempts': _consecutiveFailures,
      'source': 'repair_bot',
    });
    final ok = await CloudflareFallback.report(payload);
    if (!ok) {
      // Uc erisilemezse rapor kuyrukta bekletilir; bir sonraki taramada
      // yeniden denenir (kullaniciya hicbir sey gosterilmez).
      _reported = false;
    }
  }

  /// Disaridan (ornegin indirme hatasi) gelen sessiz bildirim.
  Future<void> reportEvent(String type, Map<String, dynamic> extra) async {
    _lastIssue = type;
    notifyListeners();
    await CloudflareFallback.report(
      CloudflareFallback.deviceInfo({'event_type': type, ...extra}),
    );
  }
}
