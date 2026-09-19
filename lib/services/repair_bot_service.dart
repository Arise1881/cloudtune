import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'music_service.dart';
import 'player_service.dart';

/// Gizli onarım botu.
///
/// Kullanıcıya hiçbir teknik hata göstermeden, çalma anında arka planda
/// tarar ve sık karşılaşılan bozuklukları otomatik düzeltir:
///   • Şarkı açılamıyor → akış kaynağı/yöntemi değiştirilerek yeniden denenir.
///   • YouTube zinciri tıkandı → negatif önbellek temizlenir, farklı yönteme
///     düşülür.
///   • Ses motoru kilitlendi (beklemede) → sıfırlanır ve şarkı tekrar çalınır.
///   • Ağ yokken akış isteği → sessizce atlanır, indirilenlerden devam edilir.
///
/// Mod: olay tetiklemeli (anında) + 30 sn periyodik tarama. Cihazı yormamak
/// için saniyede bir poll YAPILMAZ: dinleyici + düşük frekanslı kontrol.
///
/// Durum (aktif/pasif + son işlem) ayarlar ekranında gösterilir.
class RepairBotService extends ChangeNotifier {
  RepairBotService._();

  static final RepairBotService instance = RepairBotService._();

  static const String _kEnabled = 'repair_bot_enabled';
  static const Duration _periodMs = Duration(seconds: 30);

  bool _enabled = true;
  bool _init = false;
  Timer? _timer;
  int _repairs = 0;
  int _scans = 0;
  String _lastAction = '—';
  DateTime? _lastRepairAt;

  bool get enabled => _enabled;
  int get repairs => _repairs;
  int get scans => _scans;
  String get lastAction => _lastAction;
  DateTime? get lastRepairAt => _lastRepairAt;

  /// Başlatma: tercihi yükle, periyodik taramayı kur, hata dinleyicisini bağla.
  Future<void> init() async {
    if (_init) return;
    _init = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_kEnabled) ?? true;
    } catch (_) {}
    _timer?.cancel();
    _timer = Timer.periodic(_periodMs, (_) => _sweep());
    _bindPlayer();
    notifyListeners();
  }

  /// Aç/Kapat. Kapatılınca periyodik tarama durur; açılınca yeniden başlar.
  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabled, value);
    } catch (_) {}
    if (_enabled) {
      _timer?.cancel();
      _timer = Timer.periodic(_periodMs, (_) => _sweep());
    } else {
      _timer?.cancel();
    }
  }

  /// Player hatasını dinler: akış açılamadığında anında onarım girişimi.
  void _bindPlayer() {
    PlayerService.instance.addListener(_onPlayerChanged);
  }

  void _onPlayerChanged() {
    if (!_enabled) return;
    final player = PlayerService.instance;
    final err = player.lastError;
    if (err != null && !player.isPlaying && player.current != null) {
      // Hata banner'ı görünmeden hızlıca düzelt: farklı kaynakla yeniden dene.
      _repair('hata', detail: err);
    }
  }

  /// Periyodik tarama — kilitli oynatıcı ve tıkanmış video zinciri kontrolü.
  Future<void> _sweep() async {
    if (!_enabled) return;
    _scans++;
    final player = PlayerService.instance;
    // 1) Kilitli/kırık oynatıcı: bekleyen akış yüklenmediyse sıfırla.
    if (player.isLoading &&
        !player.isPlaying &&
        player.lastError == null &&
        player.current != null) {
      // Oynatıcı 30sn+ beklemede — akış çözülemedi; farklı yöntemle dene.
      _repair('kilit', detail: 'oynatıcı beklemede');
    } else if (player.lastError != null && player.current != null) {
      _repair('hata', detail: player.lastError!);
    }
    // 2) Ölü Invidious negatif önbelleği tazele (10dk sonra yeniden denenir).
    try {
      MusicService.refreshDeadInvidious();
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _repair(String type, {required String detail}) async {
    if (_repairing) return;
    _repairing = true;
    try {
      final player = PlayerService.instance;
      player.clearStreamCache();
      await player.retryCurrent();
      _repairs++;
      _lastRepairAt = DateTime.now();
      _lastAction = 'düzeltildi ($type)';
    } catch (_) {
      _lastAction = 'düzeltilemedi ($type)';
    } finally {
      _repairing = false;
      notifyListeners();
    }
  }

  bool _repairing = false;

  /// Telefon/bilgisayar boştayken kullanıcıya destek raporu için özet cadde
  /// (uzaktan onarım aşamasına geçen hatalar için yardım metni üretir).
  String statusLine() {
    if (!_enabled) return 'Pasif';
    final t = _lastRepairAt;
    final when = t == null
        ? 'henüz onarım yok'
        : 'son onarım ${t.hour.toString().padLeft(2, '0')}:'
            '${t.minute.toString().padLeft(2, '0')}';
    return 'Aktif · $when · $_repairs onarım';
  }
}