import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'music_service.dart';
import 'player_service.dart';
import 'download_manager.dart';

/// Onarım botu olay türleri.
enum RepairEventType {
  streamError,
  searchEmpty,
  downloadFailed,
  playlistParseFailed,
  artistParseFailed,
  cacheCorrupted,
  networkTimeout,
  proxyFailed,
}

/// Onarım botu olay verisi.
class RepairEvent {
  final RepairEventType type;
  final String message;
  final Map<String, dynamic> context;
  final DateTime timestamp;
  final int retryCount;

  const RepairEvent({
    required this.type,
    required this.message,
    required this.context,
    required this.timestamp,
    this.retryCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'message': message,
        'context': context,
        'timestamp': timestamp.toIso8601String(),
        'retryCount': retryCount,
      };
}

/// Onarım botu durumu.
class RepairBotStatus {
  final bool isActive;
  final DateTime? lastScan;
  final int fixedCount;
  final int escalatedCount;
  final String? lastError;
  final List<RepairEvent> recentEvents;

  const RepairBotStatus({
    required this.isActive,
    this.lastScan,
    required this.fixedCount,
    required this.escalatedCount,
    this.lastError,
    required this.recentEvents,
  });

  Map<String, dynamic> toJson() => {
        'isActive': isActive,
        'lastScan': lastScan?.toIso8601String(),
        'fixedCount': fixedCount,
        'escalatedCount': escalatedCount,
        'lastError': lastError,
        'recentEvents': recentEvents.map((e) => e.toJson()).toList(),
      };

  static RepairBotStatus fromJson(Map<String, dynamic> json) => RepairBotStatus(
        isActive: json['isActive'] as bool? ?? true,
        lastScan: json['lastScan'] != null ? DateTime.parse(json['lastScan'] as String) : null,
        fixedCount: json['fixedCount'] as int? ?? 0,
        escalatedCount: json['escalatedCount'] as int? ?? 0,
        lastError: json['lastError'] as String?,
        recentEvents: (json['recentEvents'] as List<dynamic>?)
                ?.map((e) => RepairEvent(
                      type: RepairEventType.values.firstWhere(
                          (t) => t.name == e['type'],
                          orElse: () => RepairEventType.streamError),
                      message: e['message'] as String? ?? '',
                      context: Map<String, dynamic>.from(e['context'] as Map? ?? {}),
                      timestamp: DateTime.tryParse(e['timestamp'] as String? ?? '') ?? DateTime.now(),
                      retryCount: e['retryCount'] as int? ?? 0,
                    ))
                .toList() ??
            [],
      );
}

/// Arka plan onarım botu servisi.
///
/// Özellikler:
/// - Event-driven: akış/arama/indirme hatalarını dinler
/// - Polling: 30 saniyede bir sağlık kontrolü (pil dostu)
/// - Sessiz onarım: kullanıcıya hiç hata göstermez
/// - Escalation: 3 deneme başarısızsa → Cloudflare Worker → Email
class RepairBotService extends ChangeNotifier {
  RepairBotService._();
  static final RepairBotService instance = RepairBotService._();

  static const String _kStatusKey = 'repair_bot_status';
  static const String _kWorkerUrl = 'https://23d9da7b-178f-424a-8f7d-671c7708445b.cfargotunnel.com/api/repair-log';
  static const Duration _scanInterval = Duration(seconds: 10);
  static const Duration _heavyScanInterval = Duration(seconds: 60);
  static const int _maxRetriesBeforeEscalation = 3;
  static const int _maxRecentEvents = 50;

  RepairBotStatus _status = const RepairBotStatus(
    isActive: true,
    fixedCount: 0,
    escalatedCount: 0,
    recentEvents: [],
  );
  Timer? _scanTimer;
  StreamSubscription? _connectivitySub;
  bool _isScanning = false;
  DateTime? _lastHeavyScan;

  RepairBotStatus get status => _status;
  bool get isActive => _status.isActive;
  bool get isScanning => _isScanning;

  /// Botu başlatır (uygulama açılışında çağrılır).
  Future<void> initialize() async {
    await _loadStatus();
    // Arka plan görevi için Workmanager tek sefer kurulur (Android/iOS).
    try {
      await Workmanager().initialize(callbackDispatcher);
    } catch (_) {}
    if (_status.isActive) {
      _startPeriodicScan();
      _listenConnectivity();
      dev.log('RepairBot: Aktif - 10sn aralıkla mikro tarama + 60sn ağ taraması başlatıldı');
    } else {
      dev.log('RepairBot: Pasif - kullanıcı kapatmış');
    }
  }

  /// Durumu SharedPreferences'tan yükler.
  Future<void> _loadStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kStatusKey);
      if (raw != null) {
        _status = RepairBotStatus.fromJson(jsonDecode(raw));
      }
    } catch (_) {}
  }

  /// Durumu kaydeder ve UI'ı günceller.
  Future<void> _saveStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kStatusKey, jsonEncode(_status.toJson()));
    } catch (_) {}
    notifyListeners();
  }

  /// Periyodik tarama başlatır.
  void _startPeriodicScan() {
    _scanTimer?.cancel();
    // Pil dostu mikro tarama: 10sn'de bir bellek/player/cache kontrolü.
    // Ağ gerektiren ağır kontroller 60sn'de bir yapılır (_heavyScanInterval).
    _scanTimer = Timer.periodic(_scanInterval, (_) => _scanTick());
    _registerBackgroundTask();
  }

  /// Her saat darbesinde çalışır: hafif kontrolleri her zaman,
  /// ağır (ağ) kontrolleri sadece aralık dolunca yapar.
  Future<void> _scanTick() async {
    if (_isScanning || !_status.isActive) return;
    final due = _lastHeavyScan == null ||
        DateTime.now().difference(_lastHeavyScan!) >= _heavyScanInterval;
    if (due) {
      _lastHeavyScan = DateTime.now();
      await _healthScan();
    } else {
      await _microScan();
    }
  }

  /// Hafif yerel kontrol — ağ yok, pil dostu (10sn'de bir).
  Future<void> _microScan() async {
    _isScanning = true;
    try {
      await _checkCacheHealth();
      await _checkPlayerHealth();
      _status = _status.copyWith(lastScan: DateTime.now());
      await _saveStatus();
    } catch (_) {} finally {
      _isScanning = false;
    }
  }

  /// Bağlantı dinleyicisi - çevrimiçi olduğunda hemen tarama.
  void _listenConnectivity() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((result) {
      if (!result.contains(ConnectivityResult.none)) {
        _healthScan();
      }
    });
  }

  /// Workmanager arka plan görevi kaydı.
  Future<void> _registerBackgroundTask() async {
    try {
      await Workmanager().registerPeriodicTask(
        'repair-bot-scan',
        'repairBotHealthScan',
        frequency: const Duration(minutes: 15), // Minimum 15dk (OS kısıtlaması)
        constraints: Constraints(
          networkType: NetworkType.connected,
          requiresBatteryNotLow: true,
        ),
      );
    } catch (_) {}
  }

  /// Ana sağlık tarama fonksiyonu.
  Future<void> _healthScan() async {
    if (_isScanning || !_status.isActive) return;
    _isScanning = true;

    try {
      // 1. Ağ erişimi
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity.contains(ConnectivityResult.none)) {
        await _recordEvent(RepairEventType.networkTimeout,
            'İnternet bağlantısı yok', {'action': 'waiting_for_connection'});
        return;
      }

      // 2. YouTube API yanıt süresi (Invidious + InnerTube)
      await _checkApiHealth();

      // 3. Proxy durumu
      await _checkProxyHealth();

      // 4. Cache boyutu ve bozulma kontrolü
      await _checkCacheHealth();

      // 5. İndirme kuyruğu
      await _checkDownloadQueue();

      // 6. Player durumu
      await _checkPlayerHealth();

      _status = _status.copyWith(lastScan: DateTime.now());
      await _saveStatus();
      dev.log('RepairBot: Sağlık tarama tamamlandı - ${_status.fixedCount} onarım');
    } catch (e, st) {
      dev.log('RepairBot tarama hatası: $e', stackTrace: st);
      await _recordEvent(RepairEventType.networkTimeout,
          'Tarama sırasında hata: $e', {'stack': st.toString()});
    } finally {
      _isScanning = false;
    }
  }

  /// API sağlık kontrolü.
  Future<void> _checkApiHealth() async {
    // Invidious hızlı ping (MusicService iç önbelleği canlı örneklere bakarak
    // atlar; bu yöntem aynı negatif önbelleği kullanır).
    final latency = await MusicService.instance.pingInvidious();
    if (latency < 0) {
      await _recordEvent(RepairEventType.proxyFailed,
          'Invidious erişilemiyor', {'fallback': 'InnerTube'});
      MusicService.refreshDeadInvidious(); // Negatif önbelleği temizle
      await _fixCountIncrement();
      return;
    }
    if (latency > 5000) {
      await _recordEvent(RepairEventType.networkTimeout,
          'Invidious yanıt süresi yüksek: ${latency}ms',
          {'latency_ms': latency});
      // InnerTube'a geçiş otomatik yapılır (MusicService içinde)
    }
  }

  /// Proxy sağlık kontrolü.
  Future<void> _checkProxyHealth() async {
    final proxy = MusicService.proxyBaseUrl;
    if (proxy == null) return; // Proxy kapalıysa kontrol etme

    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await client.getUrl(Uri.parse('$proxy/health'));
      final res = await req.close().timeout(const Duration(seconds: 5));
      if (res.statusCode != HttpStatus.ok) {
        await _recordEvent(RepairEventType.proxyFailed,
            'Proxy health check başarısız: ${res.statusCode}', {'proxy': proxy});
        // Proxy'yi geçici devre dışı bırak
        MusicService.setStreamProxy('');
        await _fixCountIncrement();
      }
    } catch (_) {
      await _recordEvent(RepairEventType.proxyFailed,
          'Proxy erişilemiyor, devre dışı bırakılıyor', {'proxy': proxy});
      MusicService.setStreamProxy('');
      await _fixCountIncrement();
    }
  }

  /// Cache sağlık kontrolü.
  Future<void> _checkCacheHealth() async {
    try {
      // Home cache boyutu — şişmişse önce süresi dolan girişleri temizle,
      // hâlâ 200 üstündeyse tümünü boşalt (home zararsız yeniden çeker).
      final cacheSize = MusicService.homeCacheSize;
      if (cacheSize > 200) {
        final pruned = MusicService.pruneHomeCache();
        await _recordEvent(RepairEventType.cacheCorrupted,
            'Eski cache temizlendi: $pruned entry (toplam $cacheSize → ${MusicService.homeCacheSize})',
            {'cleaned': pruned});
        if (MusicService.homeCacheSize > 200) {
          await _fixCountIncrement();
        }
      }

      // Stream cache — şişmişse boşalt (çözüm her istemde yeniden yapılır).
      if (MusicService.instance.streamUrlCacheSize > 500) {
        MusicService.instance.clearStreamUrlCache();
        await _fixCountIncrement();
      }
    } catch (_) {}
  }

  /// İndirme kuyruğu kontrolü.
  Future<void> _checkDownloadQueue() async {
    final dm = DownloadManager.instance;
    final stuck = dm.progress.keys.where((id) {
      final started = dm.startedAt(id);
      if (started == null) return false;
      return dm.isCompleted(id) == false &&
          DateTime.now().difference(started) > const Duration(minutes: 10);
    }).toList();

    for (final id in stuck) {
      final song = dm.activeSong(id);
      if (song == null) continue;
      await dm.resetDownload(id);
      await Future.delayed(const Duration(seconds: 2));
      await dm.download(song);
      await _recordEvent(RepairEventType.downloadFailed,
          'Takılı indirme yeniden başlatıldı: ${song.title}',
          {'song_id': song.id});
      await _fixCountIncrement();
    }
  }

  /// Player sağlık kontrolü.
  Future<void> _checkPlayerHealth() async {
    final player = PlayerService.instance;
    final song = player.current;
    if (song == null) return;
    // Şarkı varken oynatma durduysa ve son hata akış hatasıysa → olası
    // akış arızası. PlayerService zaten sonraki adayı/sıradaki şarkıyı dener.
    if (!player.isPlaying && player.lastError != null && !player.isLoading) {
      await _recordEvent(RepairEventType.streamError,
          'Player durdu ama şarkı var: ${song.title}',
          {'song_id': song.id});
    }
  }

  /// Olay kaydı ve onarım tetikleme.
  Future<void> _recordEvent(RepairEventType type, String message,
      Map<String, dynamic> context) async {
    final event = RepairEvent(
      type: type,
      message: message,
      context: context,
      timestamp: DateTime.now(),
    );

    final events = List<RepairEvent>.from(_status.recentEvents)
      ..insert(0, event);
    if (events.length > _maxRecentEvents) {
      events.removeRange(_maxRecentEvents, events.length);
    }

    _status = _status.copyWith(
      recentEvents: events,
      lastError: message,
    );
    await _saveStatus();

    // Otomatik onarım stratejileri
    await _attemptAutoFix(type, context);
  }

  /// Otomatik onarım stratejileri.
  Future<void> _attemptAutoFix(RepairEventType type,
      Map<String, dynamic> context) async {
    switch (type) {
      case RepairEventType.streamError:
        // MusicService'in streamCandidates zaten fallback dener
        // Negatif önbelleği temizle
        MusicService.refreshDeadInvidious();
        break;
      case RepairEventType.proxyFailed:
        // Proxy zaten _checkProxyHealth'te devre dışı bırakıldı
        break;
      case RepairEventType.cacheCorrupted:
        // _checkCacheHealth'te temizlendi
        break;
      case RepairEventType.downloadFailed:
        // DownloadManager zaten retry yapıyor
        break;
      case RepairEventType.searchEmpty:
        // Farklı kaynak denenir (MusicService.search içinde)
        break;
      default:
        break;
    }

    // Aynı hata tekrar ederse escalation
    final recentSameType = _status.recentEvents
        .where((e) => e.type == type)
        .take(3)
        .length;
    if (recentSameType >= _maxRetriesBeforeEscalation) {
      await _escalate(type, context);
    }
  }

  /// Onarım sayacını artır.
  Future<void> _fixCountIncrement() async {
    _status = _status.copyWith(fixedCount: _status.fixedCount + 1);
    await _saveStatus();
  }

  /// Escalation: Cloudflare Worker → yerel rapor → Email.
  Future<void> _escalate(RepairEventType type,
      Map<String, dynamic> context) async {
    _status = _status.copyWith(escalatedCount: _status.escalatedCount + 1);
    await _saveStatus();

    final deviceInfo = await _collectDeviceInfo();
    final payload = {
      'event_type': type.name,
      'message': _status.lastError,
      'context': context,
      'device': deviceInfo,
      'timestamp': DateTime.now().toIso8601String(),
      'app_version': await _getAppVersion(),
      'recent_events': _status.recentEvents.take(10).map((e) => e.toJson()).toList(),
    };

    // 1. Yerel rapor dosyası (her zaman — cihazda iz bırakır).
    await _saveLocalReport(payload);

    // 2. Cloudflare Worker'a logla (uzaktan ajanlar / operasyon ekibi).
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final req = await client.postUrl(Uri.parse(_kWorkerUrl));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.write(jsonEncode(payload));
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode == HttpStatus.ok) {
        dev.log('RepairBot: Worker rapor alındı');
        return;
      }
    } catch (_) {}

    // 3. Worker yoksa/ulaşılamazsa rapor yerel kalır; ayarlar ekranındaki
    //    "Uzaktan Onarım Raporu" e-postayla göndermeyi sağlar.
    dev.log('RepairBot: ESCALATION - rapor kaydedildi: ${jsonEncode(payload)}');
  }

  /// Son escalasyon raporunun yerel yolu.
  Future<Directory> _reportsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/cloudtune_reports');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Raporu yerel diske JSON olarak yazar (email/manuel inceleme için).
  Future<void> _saveLocalReport(Map<String, dynamic> payload) async {
    try {
      final dir = await _reportsDir();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}/report_$stamp.json');
      await file.writeAsString(jsonEncode(payload));
    } catch (_) {}
  }

  /// El ile escalasyon (ayarlar > Uzaktan Onarım Raporu).
  Future<Map<String, dynamic>?> reportForEmail() async {
    try {
      final dir = await _reportsDir();
      final files = dir.listSync().whereType<File>().toList()..sort((a, b) =>
          b.path.compareTo(a.path));
      if (files.isEmpty) return null;
      return jsonDecode(await files.first.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Cihaz bilgilerini toplar (email/Worker logu için).
  Future<Map<String, dynamic>> _collectDeviceInfo() async {
    final info = <String, dynamic>{};
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final android = await deviceInfo.androidInfo;
        info['platform'] = 'Android';
        info['model'] = android.model;
        info['brand'] = android.brand;
        info['version'] = android.version.release;
        info['sdk'] = android.version.sdkInt;
      } else if (Platform.isIOS) {
        final ios = await deviceInfo.iosInfo;
        info['platform'] = 'iOS';
        info['model'] = ios.model;
        info['system'] = ios.systemVersion;
      } else if (Platform.isWindows) {
        info['platform'] = 'Windows';
      } else if (Platform.isLinux) {
        info['platform'] = 'Linux';
      } else if (Platform.isMacOS) {
        info['platform'] = 'macOS';
      }
    } catch (_) {}
    return info;
  }

  /// Uygulama versiyonu.
  Future<String> _getAppVersion() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      return '${pkg.version}+${pkg.buildNumber}';
    } catch (_) {
      return 'unknown';
    }
  }

  /// Dışarıdan olay bildirimi (MusicService, PlayerService, DownloadManager çağırır).
  Future<void> reportEvent(RepairEventType type, String message,
      Map<String, dynamic> context) async {
    if (!_status.isActive) return;
    await _recordEvent(type, message, context);
  }

  /// Botu aç/kapat.
  Future<void> setActive(bool active) async {
    _status = _status.copyWith(isActive: active);
    if (active) {
      _startPeriodicScan();
      _listenConnectivity();
    } else {
      _scanTimer?.cancel();
      _connectivitySub?.cancel();
    }
    await _saveStatus();
    dev.log('RepairBot: ${active ? "Aktif" : "Pasif"}');
  }

  /// Durumu sıfırla (test/debug için).
  Future<void> reset() async {
    _status = const RepairBotStatus(
      isActive: true,
      fixedCount: 0,
      escalatedCount: 0,
      recentEvents: [],
    );
    await _saveStatus();
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _connectivitySub?.cancel();
    super.dispose();
  }
}

/// CopyWith extension for RepairBotStatus
extension RepairBotStatusCopy on RepairBotStatus {
  RepairBotStatus copyWith({
    bool? isActive,
    DateTime? lastScan,
    int? fixedCount,
    int? escalatedCount,
    String? lastError,
    List<RepairEvent>? recentEvents,
  }) {
    return RepairBotStatus(
      isActive: isActive ?? this.isActive,
      lastScan: lastScan ?? this.lastScan,
      fixedCount: fixedCount ?? this.fixedCount,
      escalatedCount: escalatedCount ?? this.escalatedCount,
      lastError: lastError ?? this.lastError,
      recentEvents: recentEvents ?? this.recentEvents,
    );
  }
}

/// Workmanager callback (arka plan görevi).
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == 'repairBotHealthScan') {
      // Arka planda hafif tarama (sadece kritik kontroller)
      final connectivity = await Connectivity().checkConnectivity();
      if (!connectivity.contains(ConnectivityResult.none)) {
        MusicService.refreshDeadInvidious();
        // Proxy kontrolü
        final proxy = MusicService.proxyBaseUrl;
        if (proxy != null) {
          try {
            final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
            final req = await client.getUrl(Uri.parse('$proxy/health'));
            final res = await req.close().timeout(const Duration(seconds: 5));
            if (res.statusCode != HttpStatus.ok) {
              MusicService.setStreamProxy('');
            }
          } catch (_) {
            MusicService.setStreamProxy('');
          }
        }
      }
    }
    return Future.value(true);
  });
}
