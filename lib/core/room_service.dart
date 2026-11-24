import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' as flutter;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'player_controller.dart';

/// Internet üzerinden oda katılımı için kullanılan ortak MQTT relay.
/// Oda kodu (ve varsa şifre) kanal adresini belirler; ses verisi bu kanaldan
/// geçmez, yalnızca oda durumu/sohbet taşınır. Şarkılar her cihazda kendi
/// YouTube bağlantısıyla oynatılır.
class RoomRelay {
  static const String host = 'wss://test.mosquitto.org';
  static const int port = 8081;
  static const String topicPrefix = 'cloudtune/rooms/v1';

  /// Şifre içermeyen oda keşif kanalı.
  static const String discoveryTopic = '$topicPrefix/discovery';
}

class RoomMember {
  const RoomMember({
    required this.clientId,
    required this.name,
    required this.avatar,
    required this.avatarVersion,
    required this.isHost,
  });

  final String clientId;
  final String name;

  /// Küçük, sıkıştırılmış JPEG veri adresi (`data:image/jpeg;base64,...`).
  final String avatar;

  /// Avatar değişim sayacı; eski sürüm geçmesin diye kullanılır.
  final int avatarVersion;
  final bool isHost;

  factory RoomMember.fromJson(Map<String, dynamic> json) => RoomMember(
        clientId: '${json['clientId'] ?? ''}',
        name: '${json['name'] ?? 'Dinleyici'}',
        avatar: '${json['avatar'] ?? ''}',
        avatarVersion: (json['avatarVersion'] as num?)?.toInt() ?? 0,
        isHost: json['isHost'] == true,
      );

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'name': name,
        'isHost': isHost,
        'avatar': avatar,
        'avatarVersion': avatarVersion,
      };

  RoomMember copyWith({
    String? name,
    String? avatar,
    int? avatarVersion,
    bool? isHost,
  }) =>
      RoomMember(
        clientId: clientId,
        name: name ?? this.name,
        avatar: avatar ?? this.avatar,
        avatarVersion: avatarVersion ?? this.avatarVersion,
        isHost: isHost ?? this.isHost,
      );
}

class RoomMessage {
  const RoomMessage({
    required this.id,
    required this.clientId,
    required this.name,
    required this.text,
    required this.at,
  });

  final String id;
  final String clientId;
  final String name;
  final String text;
  final DateTime at;

  factory RoomMessage.fromJson(Map<String, dynamic> json) => RoomMessage(
        id: '${json['id'] ?? ''}',
        clientId: '${json['clientId'] ?? ''}',
        name: '${json['name'] ?? ''}',
        text: '${json['text'] ?? ''}',
        at: DateTime.fromMillisecondsSinceEpoch(
          (json['at'] as num?)?.toInt() ?? 0,
        ),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'clientId': clientId,
        'name': name,
        'text': text,
        'at': at.millisecondsSinceEpoch,
      };
}

/// Davet bağlantısından çözümlenen kod ve şifre.
class RoomInvite {
  const RoomInvite({required this.code, required this.password});

  final String code;
  final String password;
}

enum RoomJoinFailure { none, invalidCode, connection, notFound }

/// Katılımın sonucu. `join()` eski imzayı korur; ayrıntılı sonuç isteyen
/// arayüzler `joinWithResult()` kullanır.
class RoomJoinResult {
  const RoomJoinResult._({
    required this.ok,
    required this.error,
    required this.failure,
  });

  final bool ok;
  final String error;
  final RoomJoinFailure failure;

  static const RoomJoinResult success = RoomJoinResult._(
    ok: true,
    error: '',
    failure: RoomJoinFailure.none,
  );

  factory RoomJoinResult.failed(String error, RoomJoinFailure failure) =>
      RoomJoinResult._(ok: false, error: error, failure: failure);
}

/// Keşif kanalında görülen oda. Şifre asla taşınmaz, yalnızca varlığı.
class RoomDiscovery {
  const RoomDiscovery({
    required this.code,
    required this.hostId,
    required this.name,
    required this.memberCount,
    required this.hasPassword,
    required this.hostName,
    required this.seen,
  });

  final String code;
  final String hostId;
  final String name;
  final int memberCount;
  final bool hasPassword;
  final String hostName;
  final DateTime seen;

  factory RoomDiscovery.fromJson(Map<String, dynamic> json) => RoomDiscovery(
        code: RoomService.normalizeCode('${json['code'] ?? ''}'),
        hostId: '${json['hostId'] ?? ''}',
        name: '${json['roomName'] ?? ''}'.trim(),
        memberCount: (json['memberCount'] as num?)?.toInt() ?? 0,
        hasPassword: json['hasPassword'] == true,
        hostName: '${json['hostName'] ?? ''}'.trim(),
        seen: DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        'hostId': hostId,
        'roomName': name,
        'memberCount': memberCount,
        'hasPassword': hasPassword,
        'hostName': hostName,
      };
}

class RoomService extends ChangeNotifier with flutter.WidgetsBindingObserver {
  RoomService._();

  static final RoomService instance = RoomService._();

  static const _clientIdKey = 'room_client_id';
  static const _consentKey = 'room_remote_data_consent';
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// Kabaca 100 KB JPEG için base64 karakter sınırı.
  static const int maxAvatarDataUrlChars = 140000;

  /// Syncwatch tarzı eşzamanlı çalma: çalma konumu saate bağlanır. Wi-Fi'de
  /// 2 sn, mobil veride 4 sn'lik kalp atışı yeterli olur; komutlar anında gider.
  static const Duration _stateTickWifi = Duration(seconds: 2);
  static const Duration _stateTickMobile = Duration(seconds: 4);
  static const Duration _presenceTickWifi = Duration(seconds: 8);
  static const Duration _presenceTickMobile = Duration(seconds: 16);
  static const Duration _discoveryTickWifi = Duration(seconds: 5);
  static const Duration _discoveryTickMobile = Duration(seconds: 10);

  /// Medya kaynağı açılışı uzayabilir (zayıf bağlantıda 20 sn'ye kadar).
  /// Oda kilitlerini bu kadar uzun tutmak state'leri işlenmez kıldığı için
  /// player işlemlerini sınırlar; alttaki Future devam etse bile sync bloke olmaz.
  static const Duration _playerOpTimeout = Duration(seconds: 4);

  /// Bir odada taşınabilecek en fazla parça ve bağlantı kopukluğunda bekletilen
  /// en fazla mesaj. Mobil veride Paket başına maliyet bu sınırlarla sabitlenir.
  static const int _queueLimit = 100;
  static const int _maxQueuedPublishes = 24;
  static const Duration _commandTtl = Duration(seconds: 30);

  static String _clientId = '';
  static Future<void>? _initFuture;

  /// `init()` statik olduğu için onay bilgisi önce statik alana alınır.
  static bool? _initialConsent;

  static String get clientId => _clientId;

  String? _roomId;
  String _roomName = '';
  String _password = '';
  String _displayName = '';
  bool _isHost = false;
  bool _autoSync = true;
  bool _busy = false;
  String _error = '';
  bool _remoteDataAllowed = false;
  String _avatarDataUrl = '';
  int _avatarVersion = 0;

  final Map<String, RoomMember> _members = {};
  final List<RoomMessage> _chat = [];
  final Map<String, int> _reactions = {};
  final Map<String, DateTime> _memberSeen = {};
  final Map<String, RoomDiscovery> _discovered = {};
  List<Track> _queue = const [];
  Map<String, dynamic>? _playback;

  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _messageSub;
  Timer? _presenceTimer;
  Timer? _stateTimer;
  Timer? _pruneTimer;
  DateTime _lastStatePublish = DateTime.fromMillisecondsSinceEpoch(0);
  int _stateSeq = 0;
  Map<String, dynamic>? _lastRemoteState;
  bool _applyingRemote = false;
  Map<String, dynamic>? _pendingRemoteState;
  Completer<bool>? _ackCompleter;

  /// Paylaşılan sıranın sürümü. Yalnızca liste değişince artar; kalp atışları
  /// tüm sırayı yeniden göndermez, mobil veri trafiği ~10 kat azalır.
  int _queueRev = 0;
  int _sentQueueRev = -1;

  /// Host değişiminde eski sunucunun geç kalan paketleri ayırt edilir.
  int _hostEpoch = 0;

  /// Host saati - yerel saat. NTP benzeri gidiş-dönüş ölçümüyle hesaplanır;
  /// konum tahmininde ağ gecikmesi telafi edilir.
  int _clockOffsetMs = 0;
  final Map<String, int> _probeSend = {};
  final Set<String> _seenCommands = {};

  /// Bağlantı yokken yayınlanamayan mesajlar. QoS1 tekrarlarla birlikte
  /// kopuklukta kaybolan play/pause komutlarını da kurtarır.
  final List<Map<String, dynamic>> _queuedPublishes = [];

  bool _mobileData = false;
  bool _online = true;
  bool _avatarDirty = false;
  int _presenceParity = 0;
  int _stateParity = 0;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _connectivityWatchStarted = false;
  Timer? _rateTimer;

  MqttServerClient? _discoveryClient;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _discoverySub;
  Timer? _discoveryTimer;
  Timer? _discoveryRetryTimer;
  int _discoveryFailures = 0;
  bool _discoveryStarting = false;
  String _discoveryError = '';

  String? get roomId => _roomId;
  String get roomName => _roomName;
  bool get hasPassword => _password.isNotEmpty;
  bool get isHost => _isHost;
  bool get inRoom => _roomId != null;
  bool get busy => _busy;
  String get error => _error;
  bool get autoSync => _autoSync;

  /// Kullanıcı, diğer cihazların oda bilgilerini görmeyi onayladı mı?
  bool get remoteDataAllowed => _remoteDataAllowed || (_initialConsent ?? false);

  /// Keşif kanalında görülen aktif odalar (en yeni görülen önce).
  List<RoomDiscovery> get discoveredRooms {
    final list = _discovered.values.toList()
      ..sort((a, b) => b.seen.compareTo(a.seen));
    return List<RoomDiscovery>.unmodifiable(list);
  }

  String get discoveryError => _discoveryError;

  List<RoomMember> get members {
    // Ev sahibi önce, sonra sabit sıralama: avatar geçişi liste sırasını
    // sürekli değiştirmesin.
    final list = _members.values.toList()
      ..sort((a, b) {
        final host = (b.isHost ? 1 : 0) - (a.isHost ? 1 : 0);
        if (host != 0) return host;
        return a.clientId.compareTo(b.clientId);
      });
    return List<RoomMember>.unmodifiable(list);
  }

  List<RoomMessage> get chat => List<RoomMessage>.unmodifiable(_chat);
  Map<String, int> get reactions => Map<String, int>.unmodifiable(_reactions);
  List<Track> get queue => List<Track>.unmodifiable(_queue);
  Map<String, dynamic>? get playback => _playback;

  /// Kullanıcı tarafından kopyalanan http davet bağlantısı. Şifre `?p=`
  /// parametresinde taşınır; bağlantı tek başına katılım için yeterlidir.
  /// Eski `cloudtune://` biçimi [parseInvite] tarafından hâlâ kabul edilir.
  String get inviteLink {
    final code = _roomId;
    if (code == null) return '';
    final base = 'http://cloudtune.app/room/$code';
    if (!hasPassword) return base;
    return '$base?p=${Uri.encodeComponent(_password)}';
  }

  String get roomPassword => _password;

  /// Paylaşılan sıranın sürümü; arayüz "senkron" göstergesinde kullanılır.
  int get queueRevision => _queueRev;

  /// Host ile yerel saat arasındaki tahmini fark (ms).
  int get clockOffsetMs => _clockOffsetMs;

  /// Mobil veride daha seyrek kalp atışı ve daha küçük paket kullanılır.
  bool get mobileData => _mobileData;

  /// Ağ türüne göre oda trafiği sıklığı. Statik olmaları test edilebilir
  /// kılıyor ve zamanlayıcıların tek kaynaktan beslenmesini sağlıyor.
  static Duration stateInterval({required bool mobileData}) =>
      mobileData ? _stateTickMobile : _stateTickWifi;

  static Duration presenceInterval({required bool mobileData}) =>
      mobileData ? _presenceTickMobile : _presenceTickWifi;

  static Duration discoveryInterval({required bool mobileData}) =>
      mobileData ? _discoveryTickMobile : _discoveryTickWifi;

  /// Tam sıranın kaçıncı kalp atışında bir yeniden gönderileceği.
  /// Mobil veride daha seyrek; sıra değişimleri yine anında yayınlanır.
  static int queueRefreshTicks({required bool mobileData}) =>
      mobileData ? 12 : 8;

  /// Misafirin host saatiyle arasındaki kaymayı ölçme sıklığı (tick).
  static int clockProbeTicks({required bool mobileData}) =>
      mobileData ? 8 : 4;

  /// Ev sahibinin gerçek çalar kuyruğunu ve konumunu taşıyan state mesajı.
  /// Radyo/sıralama kuyruğu ile oda kuyruğunun ayrışması eşzamanlı çalmayı
  /// bozduğu için kaynak tek noktada üretilir.
  static Map<String, dynamic> buildStatePayload({
    required String roomName,
    required List<Track> tracks,
    required int index,
    required int positionMs,
    required bool playing,
    int seq = 0,
    int sentAt = 0,
    String hostId = '',
    int queueRev = 0,
    bool includeQueue = true,
    int epoch = 0,
  }) {
    final safeIndex =
        tracks.isEmpty ? 0 : index.clamp(0, tracks.length - 1);
    final track = tracks.isEmpty ? null : tracks[safeIndex];
    return <String, dynamic>{
      'roomName': roomName,
      // MQTT QoS1 aynı paketi iki kez teslim edebilir; sıra ve zaman damgası
      // olmadan eski bir state yeni parçayı geri alabiliyordu.
      'seq': seq,
      'sentAt': sentAt,
      'hostId': hostId,
      'queueRev': queueRev,
      'epoch': epoch,
      // Kalp atışında sıra gönderilmez; alıcı son bilinen sırayı korur.
      // Eski sürüm client'lar `queue` olmadığında mevcut listesini kullanır.
      'queue': includeQueue
          ? tracks.map((item) => item.toJson()).toList()
          : null,
      'playback': track == null
          ? <String, dynamic>{
              'id': '',
              'index': 0,
              'positionMs': 0,
              'playing': false,
              'stopped': true,
            }
          : <String, dynamic>{
              ...track.toJson(),
              'index': safeIndex,
              'positionMs': positionMs,
              'playing': playing,
              'stopped': false,
            },
    };
  }

  static int _stateNumber(dynamic value) =>
      value is num ? value.toInt() : 0;

  /// QoS1 tekrarı, geciken paket veya host değişiminden sonra eski state
  /// uygulanmasın diye host dönemi + zaman + sıra karşılaştırması yapılır.
  static bool isRemoteStateNewer(
    Map<String, dynamic> incoming,
    Map<String, dynamic>? current,
  ) {
    if (current == null) return true;
    final incomingEpoch = _stateNumber(incoming['epoch']);
    final currentEpoch = _stateNumber(current['epoch']);
    if (incomingEpoch != currentEpoch) return incomingEpoch > currentEpoch;
    final incomingAt = _stateNumber(incoming['sentAt']);
    final currentAt = _stateNumber(current['sentAt']);
    if (incomingAt != currentAt) return incomingAt > currentAt;
    final incomingSeq = _stateNumber(incoming['seq']);
    final currentSeq = _stateNumber(current['seq']);
    if (incomingSeq != currentSeq) return incomingSeq > currentSeq;
    // Eski host kimliği boşsa kesinlikle daha yeni sayılmaz. İkisi de dolu
    // ve eşit zaman/sıraysa deterministik karşılaştırma gerekir; aksi halde
    // aynı paket iki kez gelince "daha yeni" sanılıp gereksiz seek yapılırdı.
    final incomingHost = '${incoming['hostId'] ?? ''}';
    final currentHost = '${current['hostId'] ?? ''}';
    if (incomingHost.isEmpty) return false;
    if (currentHost.isEmpty) return true;
    return incomingHost.compareTo(currentHost) > 0;
  }

  /// NTP benzeri gidiş-dönüş ölçümü: `t0` yerel gönderim, `t1` host varış,
  /// `t2` host yanıt, `t3` yerel varış (ms). Host `t2 = t1` olarak döndürür.
  static int clockOffset({
    required int t0,
    required int t1,
    required int t2,
    required int t3,
  }) {
    final forward = t1 - t0;
    final backward = t2 - t3;
    return ((forward + backward) / 2).round();
  }

  /// Host'un `sentAt` anında ölçtüğü konumu, yerel saate ve tahmini saat
  /// farkına göre bugüne taşır. Duraklatılmışsa konum sabit kalır.
  static int syncTargetMs({
    required int positionMs,
    required int sentAt,
    required int nowMs,
    required bool playing,
    int offsetMs = 0,
  }) {
    if (!playing || sentAt <= 0) return positionMs;
    final elapsed = nowMs + offsetMs - sentAt;
    // Saat farkı çok büyükse (yanlış NTP) tahmini kullanma; ham konum daha
    // güvenlidir.
    if (elapsed.isNegative || elapsed > 60000) return positionMs;
    return positionMs + elapsed;
  }

  /// Her cihazın aynı komutu bir kez uygulaması için benzersiz kimlik.
  static String commandId(String clientId) =>
      '${clientId}_${DateTime.now().microsecondsSinceEpoch}';

  /// Komut zarfı; oda kanalı dışına çıkmaz, şifre taşımaz.
  static Map<String, dynamic> buildCommand({
    required String id,
    required String action,
    required Map<String, dynamic> payload,
  }) =>
      <String, dynamic>{
        'id': id,
        'action': action,
        'at': DateTime.now().millisecondsSinceEpoch,
        ...payload,
      };

  /// Gelen index yabancı kuyruğa ait olabilir; parça id'si her zaman
  /// önceliklidir. Böylece sıra/radyo değişince joiner yanlış parçaya atlamaz.
  static int resolveStateIndex(
    List<Track> tracks,
    Map<String, dynamic> playback,
  ) {
    if (tracks.isEmpty) return 0;
    final id = playback['id']?.toString() ?? '';
    if (id.isNotEmpty) {
      final found = tracks.indexWhere((track) => track.id == id);
      if (found >= 0) return found;
    }
    final fallback = (playback['index'] as num?)?.toInt() ?? 0;
    return fallback.clamp(0, tracks.length - 1);
  }

  static bool _sameQueue(List<Track> local, List<Track> remote) {
    if (local.length != remote.length) return false;
    for (var i = 0; i < local.length; i++) {
      if (local[i].id != remote[i].id) return false;
    }
    return true;
  }

  /// Oda kodları büyük harf, boşluksuz ve MQTT topic'i için güvenli olmalı.
  /// Ağdan gelen bozuk kodlar doğrulanmadan topic'e concat edilmesin.
  static String normalizeCode(String code) {
    final cleaned = code.trim().toUpperCase();
    if (cleaned.isEmpty || cleaned.length > 12) return '';
    if (!RegExp(r'^[A-Z0-9-]+$').hasMatch(cleaned)) return '';
    return cleaned;
  }

  /// Şifreler tutarlı biçimde sadece kenar boşluklarından arındırılır;
  /// büyük/küçük harf anlamlıdır, değiştirilmez.
  static String normalizePassword(String password) => password.trim();

  /// `cloudtune://room/KOD?p=...` veya `https://cloudtune.app/room/KOD?p=...`
  /// biçimlerini ve düz kodu çözümler.
  static RoomInvite? parseInvite(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;

    // Düz oda kodu (davet linki olmadan paylaşılmış olabilir).
    if (RegExp(r'^[A-Za-z0-9]{4,12}$').hasMatch(text)) {
      final code = normalizeCode(text);
      if (code.isEmpty) return null;
      return RoomInvite(code: code, password: '');
    }

    if (!text.contains('://')) {
      if (text.toLowerCase().startsWith('cloudtune.app/')) {
        text = 'https://$text';
      } else {
        return null;
      }
    }

    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    final scheme = uri.scheme.toLowerCase();
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();

    String code = '';
    if (scheme == 'cloudtune' && uri.host.toLowerCase() == 'room') {
      if (segments.isNotEmpty) code = segments.first;
    } else if ((scheme == 'https' || scheme == 'http') &&
        uri.host.toLowerCase() == 'cloudtune.app' &&
        segments.isNotEmpty &&
        segments.first.toLowerCase() == 'room') {
      if (segments.length > 1) code = segments[1];
    }
    code = normalizeCode(code);
    if (code.isEmpty) return null;

    return RoomInvite(
      code: code,
      password: normalizePassword(uri.queryParameters['p'] ?? ''),
    );
  }

  /// Aynı anda birden çok yerden çağrılsa da tek seferde başlar.
  static Future<void> init() => _initFuture ??= _init();

  static Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_clientIdKey) ?? '';
    if (id.isEmpty) {
      final random = Random.secure();
      id =
          List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join();
      await prefs.setString(_clientIdKey, id);
    }
    _clientId = id;
    _initialConsent = prefs.getBool(_consentKey) ?? false;
  }

  static String _code() {
    final random = Random.secure();
    return List.generate(6, (_) => _alphabet[random.nextInt(_alphabet.length)])
        .join();
  }

  /// Kanal, kod ve şifrenin kısa özetinden oluşur. Böylece yalnızca kodu
  /// ve şifreyi bilenler aynı odaya düşer; şifre relay'e gönderilmez.
  static String _channel(String code, String password) {
    var hash = 2166136261;
    for (final unit in normalizePassword(password).codeUnits) {
      hash ^= unit;
      hash = (hash * 16777619) & 0xFFFFFFFF;
    }
    return '${normalizeCode(code)}-${hash.toRadixString(16).padLeft(8, '0')}';
  }

  String get _topic =>
      '${RoomRelay.topicPrefix}/${_channel(_roomId ?? '', _password)}/events';

  Future<bool> create({
    required String name,
    required String password,
    String avatar = '',
    String displayName = '',
  }) async {
    final result = await _enter(
      code: _code(),
      name: name,
      password: password,
      avatar: avatar,
      displayName: displayName,
      isHost: true,
      requireAck: false,
    );
    return result.ok;
  }

  Future<bool> join({
    required String code,
    required String password,
    String avatar = '',
    String displayName = '',
  }) async {
    final result = await joinWithResult(
      code: code,
      password: password,
      avatar: avatar,
      displayName: displayName,
    );
    if (!result.ok) _error = result.error;
    return result.ok;
  }

  /// Eski `join()` imzasını korur; hata mesajını sonuç içinde de döndürür.
  Future<RoomJoinResult> joinWithResult({
    required String code,
    required String password,
    String avatar = '',
    String displayName = '',
  }) =>
      _enter(
        code: code,
        name: 'Oda ${normalizeCode(code)}',
        password: password,
        avatar: avatar,
        displayName: displayName,
        isHost: false,
        requireAck: true,
      );

  Future<RoomJoinResult> _enter({
    required String code,
    required String name,
    required String password,
    String avatar = '',
    required String displayName,
    required bool isHost,
    required bool requireAck,
  }) async {
    final clean = normalizeCode(code);
    if (clean.isEmpty) {
      _error = 'Oda kodu gerekli.';
      notifyListeners();
      return RoomJoinResult.failed(_error, RoomJoinFailure.invalidCode);
    }

    await init();
    _setBusy(true, '');
    await _detach(publishBye: false);

    _roomId = clean;
    _roomName = name.trim().isEmpty ? 'Oda $clean' : name.trim();
    _password = normalizePassword(password);
    _displayName =
        displayName.trim().isEmpty ? 'Dinleyici' : displayName.trim();
    _isHost = isHost;
    _members.clear();
    _chat.clear();
    _reactions.clear();
    _memberSeen.clear();
    _queue = const [];
    _playback = null;
    _stateSeq = 0;
    _lastRemoteState = null;
    _pendingRemoteState = null;
    _applyingRemote = false;
    _queueRev = 0;
    _sentQueueRev = -1;
    _hostEpoch = isHost ? _hostEpoch + 1 : 0;
    _clockOffsetMs = 0;
    _probeSend.clear();
    _seenCommands.clear();
    _queuedPublishes.clear();
    _cancelRateCorrection();

    unawaited(_watchConnectivity());

    final connected = await _attach();
    if (!connected) {
      final message =
          _error.isEmpty ? 'Odaya bağlanılamadı.' : _error;
      _clearRoom();
      _setBusy(false, message);
      return RoomJoinResult.failed(message, RoomJoinFailure.connection);
    }

    PlayerController.instance.addListener(_onLocalPlayerChanged);
    flutter.WidgetsBinding.instance.addObserver(this);
    _presenceTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      _presenceParity++;
      // Mobil veride her iki presence bir atlanır (16 sn'de bir). Wi-Fi'de 8 sn.
      if (_mobileData && _presenceParity % 2 != 0) return;
      _publishPresence();
      _pruneMembers();
    });
    _presenceParity = 0;
    _stateParity = 0;
    _startStateTimer();
    // İlk presence avatarı taşır; diğer cihaz yeni katılımcıyı hemen görsün.
    // uploadAvatar sonrası gelen ikinci presence yalnızca avatar değiştiğinde
    // gönderilir (aynı veri tekrar gönderilmez).
    _publishPresence(includeAvatar: true);
    if (avatar.isNotEmpty) unawaited(uploadAvatar(avatar));
    if (_isHost) {
      // Oda, host'un o anda çaldığı parçayla başlar. Paylaşılan sıra artık
      // çalar kuyruğundan bağımsız değil; her iki cihaz da aynı listeyi görür.
      final player = PlayerController.instance;
      if (player.tracks.isNotEmpty) {
        _queue = List<Track>.unmodifiable(
          player.tracks.take(_queueLimit).toList(),
        );
        _queueRev++;
        _playback = <String, dynamic>{
          ...player.current!.toJson(),
          'index': player.index,
          'positionMs': player.position.inMilliseconds,
          'playing': player.playing,
        };
      }
      _publishState(force: true);
    }

    // Ev sahibi keşif kanalında görünsün; katılanlar zaten dinliyor.
    unawaited(startDiscovery().then((_) => _publishDiscovery()));

    if (requireAck) {
      final completer = Completer<bool>();
      _ackCompleter = completer;
      _publish('hello', {'requestPresence': true});
      final acknowledged = await completer.future.timeout(
        const Duration(seconds: 6),
        onTimeout: () => false,
      );
      if (_ackCompleter == completer) _ackCompleter = null;
      if (!acknowledged) {
        await _detach(publishBye: false);
        _clearRoom();
        const message = 'Oda bulunamadı veya şifre yanlış';
        _setBusy(false, message);
        return RoomJoinResult.failed(message, RoomJoinFailure.notFound);
      }
    }

    // ack host varlığını doğrular; state_request ilk oda durumunu hemen ister.
    // hello kaybolursa periyodik yayını beklemek gerekmez. clock probe ile
    // konum tahmini ilk günden itibaren ağ gecikmesini telafi eder.
    if (!_isHost) {
      _publish('state_request', const <String, dynamic>{});
      _sendTimeProbe();
    }

    _setBusy(false, '');
    return RoomJoinResult.success;
  }

  Future<bool> _attach() async {
    MqttServerClient? client;
    try {
      // Yeniden bağlanmada suffix değişmesin: aynı istemci kimliği korunur.
      final id = 'ct_$_clientId';
      client = MqttServerClient.withPort(
        RoomRelay.host,
        id,
        RoomRelay.port,
      );
      client.useWebSocket = true;
      client.websocketProtocols = MqttClientConstants.protocolsSingleDefault;
      client.keepAlivePeriod = 20;
      client.autoReconnect = true;
      client.logging(on: false);
      client.setProtocolV311();
      // Son istek (LWT): cihaz aniden düşerse diğer cihaz 18 sn beklemeden
      // üyeyi kaldırır ve host yoksa yeni host seçilir.
      final bye = jsonEncode(<String, dynamic>{
        'room': _roomId,
        'channel': _channel(_roomId ?? '', _password),
        'type': 'bye',
        'clientId': id,
        'name': _displayName,
        'isHost': _isHost,
        'at': DateTime.now().millisecondsSinceEpoch,
        'payload': <String, dynamic>{'reason': 'lwt'},
      });
      client.connectionMessage = MqttConnectMessage()
          .withClientIdentifier(id)
          .startClean()
          .withWillTopic(_topic)
          .withWillMessage(bye)
          .withWillQos(MqttQos.atLeastOnce);
      client.onDisconnected = () {
        if (!inRoom) return;
        _error = 'Bağlantı koptu, yeniden deneniyor…';
        notifyListeners();
      };
      client.onAutoReconnect = () {
        if (!inRoom) return;
        _error = 'Relay bağlantısı yeniden kuruluyor…';
        notifyListeners();
      };
      client.onConnected = () {
        if (!inRoom) return;
        _error = '';
        notifyListeners();
        // Kopuklukta kaçan komutları gönder, state'i yeniden iste. Gecikmeli
        // gönderim abone yeniden kurulmadan önce kaybolmasın diye kullanılır.
        Timer(const Duration(milliseconds: 1200), () {
          if (!inRoom) return;
          _flushQueuedPublishes();
          if (!_isHost) {
            _publishPresence();
            _publish('state_request', const <String, dynamic>{});
            _publish('time_probe', <String, dynamic>{
              't0': DateTime.now().millisecondsSinceEpoch,
            });
          } else {
            _publishState(force: true);
          }
        });
      };

      final status = await client
          .connect()
          .timeout(const Duration(seconds: 15), onTimeout: () => null);
      final refused = status?.returnCode;
      if (refused != null &&
          refused != MqttConnectReturnCode.connectionAccepted) {
        client.disconnect();
        _error = _connectionMessage(refused);
        return false;
      }
      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        client.disconnect();
        _error = 'Relay sunucusuna ulaşılamadı.';
        return false;
      }

      client.subscribe(_topic, MqttQos.atLeastOnce);
      _messageSub = client.updates?.listen(_onMessages);
      _client = client;
      return true;
    } catch (error) {
      // connect() sonrası bir istisna autoReconnect'li istemciyi referanssız
      // bırakıyordu; her başarısız katılım bir soket/zamanlayıcı sızdırıyordu.
      if (client != null) {
        try {
          client.disconnect();
        } catch (_) {}
      }
      if (_client == null) {
        await _messageSub?.cancel();
        _messageSub = null;
      }
      _error = 'Bağlantı hatası: ${_shortError(error)}';
      return false;
    }
  }

  static String _connectionMessage(MqttConnectReturnCode code) {
    switch (code) {
      case MqttConnectReturnCode.unacceptedProtocolVersion:
        return 'Relay: protokol sürümü reddedildi.';
      case MqttConnectReturnCode.identifierRejected:
        return 'Relay: istemci kimliği reddedildi.';
      case MqttConnectReturnCode.brokerUnavailable:
        return 'Relay sunucusu kullanılamıyor.';
      case MqttConnectReturnCode.badUsernameOrPassword:
        return 'Relay: kimlik doğrulama başarısız.';
      case MqttConnectReturnCode.notAuthorized:
        return 'Relay: yetki yok.';
      default:
        return 'Relay bağlantısı reddedildi.';
    }
  }

  static String _shortError(Object error) {
    final text = error.toString().trim();
    if (text.isEmpty) return 'bilinmeyen hata';
    return text.split(RegExp(r'\s')).first;
  }

  void _onMessages(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final received in messages) {
      final publish = received.payload as MqttPublishMessage?;
      if (publish == null) continue;
      final raw = MqttPublishPayload.bytesToStringAsString(
        publish.payload.message,
      );
      Map<String, dynamic> envelope;
      try {
        envelope = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (envelope['room'] != _roomId ||
          envelope['channel'] != _channel(_roomId ?? '', _password)) {
        continue;
      }
      if (envelope['clientId'] == _clientId) continue;
      _handle(envelope);
    }
  }

  void _handle(Map<String, dynamic> envelope) {
    final type = envelope['type']?.toString();
    final payload = envelope['payload'];
    final payloadMap = payload is Map
        ? Map<String, dynamic>.from(payload)
        : <String, dynamic>{};
    final remoteId = envelope['clientId']?.toString() ?? '';
    final current = _members[remoteId];

    // Onay verilmeden uzak avatar verisi saklanmaz/gösterilmez.
    final incomingAvatar = remoteDataAllowed
        ? (payloadMap['avatar']?.toString() ?? current?.avatar ?? '')
        : '';
    final incomingVersion = (payloadMap['avatarVersion'] as num?)?.toInt() ??
        current?.avatarVersion ??
        0;
    final member = RoomMember(
      clientId: remoteId,
      name: envelope['name']?.toString() ?? 'Dinleyici',
      avatar: incomingAvatar,
      avatarVersion: incomingVersion,
      isHost: envelope['isHost'] == true,
    );

    switch (type) {
      case 'presence':
        _putMember(_mergeMember(current, member));
        _memberSeen[remoteId] = DateTime.now();
        if (payloadMap['roomName'] is String &&
            (payloadMap['roomName'] as String).isNotEmpty) {
          _roomName = payloadMap['roomName'] as String;
        }
        notifyListeners();

      case 'hello':
        _putMember(_mergeMember(current, member));
        _memberSeen[remoteId] = DateTime.now();
        if (_isHost) {
          // Yalnızca ev sahibi oda varlığını doğrular; şifre yanlışsa
          // katılan başka kanalda olduğu için hello hiç ulaşmaz.
          _publish('ack', {'to': remoteId});
          if (payloadMap['requestPresence'] == true) {
            // Katılan kişi avatarları hemen görmek istiyor. Periyodik
            // presence'ı beklemeden tüm üyelerden presence iste.
            _publishPresence(includeAvatar: true);
            _publishState(force: true);
            _publish('presence_request', const {});
          }
        }
        notifyListeners();

      case 'presence_request':
        // Ev sahibi yeni katılımda istedi; avatarı da gönder ki yeni üye
        // katılımcıları görebilsin. State'i yalnızca host gönderir.
        if (!_isHost) _publishPresence(includeAvatar: true);

      case 'ack':
        if (payloadMap['to'] == _clientId && member.isHost) {
          // ack yalnızca gerçek ev sahibinden gelirse katılım onaylanır.
          final completer = _ackCompleter;
          if (completer != null && !completer.isCompleted) {
            completer.complete(true);
          }
        }

      case 'bye':
        _members.remove(remoteId);
        _memberSeen.remove(remoteId);
        // Host aniden düşerse oda donmasın: kalan ilk üye yeni host olur.
        if (member.isHost && !_isHost && _members.isNotEmpty) {
          final next = _members.keys.reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
          if (next == _clientId) _becomeHost();
        }
        notifyListeners();

      case 'command':
        // Her cihaz aynı komutu uygular; kimse tekrar yayınlamaz. Host ayrıca
        // bir state yayınlayarak geç kalan katılımcıları da yakalar.
        _handleCommand(payloadMap, remoteId);
        break;

      case 'time_probe':
        _publish('time_probe_ack', <String, dynamic>{
          'to': remoteId,
          't0': payloadMap['t0'],
          't1': DateTime.now().millisecondsSinceEpoch,
        });
        break;

      case 'time_probe_ack':
        if (payloadMap['to'] == _clientId) {
          final t0 = (payloadMap['t0'] as num?)?.toInt();
          final t1 = (payloadMap['t1'] as num?)?.toInt();
          if (t0 != null && t1 != null) {
            _probeSend.remove('$t0');
            final offset = clockOffset(
              t0: t0,
              t1: t1,
              t2: t1,
              t3: DateTime.now().millisecondsSinceEpoch,
            );
            // Ani sapmaları süzer; ölçüm gürültüsü konumu oynatmasın.
            if (offset.abs() < 60000) {
              _clockOffsetMs = _clockOffsetMs == 0
                  ? offset
                  : ((_clockOffsetMs * 3 + offset) / 4).round();
            }
            notifyListeners();
          }
        }
        break;

      case 'kick':
        if (payloadMap['memberId'] == _clientId) {
          unawaited(_removedByHost());
        }

      case 'host_transfer':
        // payload.memberId = YENİ host. Eski kod remoteId'yi (eski host'u)
        // host sanıyordu; transfer sonrası kimse state yayınlamıyordu.
        final targetId = payloadMap['memberId']?.toString() ?? '';
        if (targetId.isNotEmpty) {
          for (final entry in _members.entries.toList()) {
            _members[entry.key] =
                entry.value.copyWith(isHost: entry.key == targetId);
          }
          if (targetId == _clientId && !_isHost) _becomeHost();
          notifyListeners();
        }

      case 'state_request':
        if (_isHost) _publishState(force: true);

      case 'state':
        if (payload is Map && !_isHost) {
          // Eski sürüm/relay paketlerinde sentAt yoksa zarf zamanını kullan.
          final state = Map<String, dynamic>.from(payload);
          state.putIfAbsent(
            'sentAt',
            () => (envelope['at'] as num?)?.toInt() ?? 0,
          );
          state.putIfAbsent('seq', () => 0);
          state.putIfAbsent('hostId', () => remoteId);
          unawaited(_applyRemoteState(state));
        }

      case 'chat':
        if (payload is Map) {
          final message =
              RoomMessage.fromJson(Map<String, dynamic>.from(payload));
          _chat.add(message);
          if (_chat.length > 60) _chat.removeAt(0);
          notifyListeners();
        }

      case 'reaction':
        final emoji = payloadMap['emoji']?.toString() ?? '';
        if (emoji.isNotEmpty) {
          _reactions[emoji] = (_reactions[emoji] ?? 0) + 1;
          notifyListeners();
        }
    }
  }

  static RoomMember _mergeMember(RoomMember? current, RoomMember incoming) {
    final old = current;
    if (old == null) return incoming;
    // Eski sürüm geç gelirse avatarı geri almayalım; isim/host bilgisi
    // yine de güncellenir.
    if (incoming.avatarVersion >= old.avatarVersion) return incoming;
    return old.copyWith(name: incoming.name, isHost: incoming.isHost);
  }

  void _putMember(RoomMember member) {
    if (member.clientId.isEmpty) return;
    _members[member.clientId] = member;
  }

  /// Host düştüğünde veya transfer edildiğinde yeni host state'i devralır.
  /// Epoch artışı, eski host'un gecikmiş paketlerinin uygulanmasını engeller.
  void _becomeHost() {
    if (_isHost) return;
    _isHost = true;
    _hostEpoch++;
    _lastRemoteState = null;
    _pendingRemoteState = null;
    _sentQueueRev = -1;
    _clockOffsetMs = 0;
    _startStateTimer();
    _publishPresence();
    _publishState(force: true);
    _publish('state_request', const <String, dynamic>{});
    notifyListeners();
  }

  void _sendTimeProbe() {
    final t0 = DateTime.now().millisecondsSinceEpoch;
    _probeSend['$t0'] = t0;
    if (_probeSend.length > 8) _probeSend.remove(_probeSend.keys.first);
    _publish('time_probe', <String, dynamic>{'t0': t0});
  }

  // ---------------------------------------------------------------------
  // İki yönlü oda komutları (syncwatch)
  // ---------------------------------------------------------------------

  void _handleCommand(Map<String, dynamic> payload, String _) {
    final id = payload['id']?.toString() ?? '';
    if (id.isEmpty || !_seenCommands.add(id)) return;
    if (_seenCommands.length > 200) {
      _seenCommands.remove(_seenCommands.first);
    }
    final at = (payload['at'] as num?)?.toInt() ?? 0;
    if (at > 0 &&
        DateTime.now().millisecondsSinceEpoch - at >
            _commandTtl.inMilliseconds) {
      return;
    }
    unawaited(_applyCommand('${payload['action'] ?? ''}', payload));
    // Host, komutu alan herkese güncel durumu bir kez daha bildirir; böylece
    // paketi kaçıran cihaz da bir sonraki tick'i beklemeden yakalar.
    if (_isHost) _publishState(force: true);
  }

  /// Paylaşılan kuyrukta çalan parçanın sırası. Bulunamazsa ilk parça kabul
  /// edilir; next bu durumda ikinci parçaya geçer.
  int _queueIndex(PlayerController player) {
    final id = player.current?.id;
    if (id == null) return 0;
    final found = _queue.indexWhere((track) => track.id == id);
    return found >= 0 ? found : 0;
  }

  Future<void> _playerOp(Future<void> Function() operation) async {
    try {
      await operation().timeout(_playerOpTimeout);
    } on TimeoutException {
      if (kDebugMode) debugPrint('CT room player op timeout');
    }
  }

  /// Kilidi bırakır ve biriken en yeni state'i uygular. Komut içinde kilit
  /// zaten tutuluyorsa (wasApplying) bekleyen state bırakılmaz; gerçek sahibi
  /// bitirdiğinde alınır.
  void _releaseApplyingRemote(bool wasApplying) {
    _applyingRemote = wasApplying;
    if (_applyingRemote) return;
    final pending = _pendingRemoteState;
    _pendingRemoteState = null;
    if (pending != null) unawaited(_applyRemoteState(pending));
  }

  Future<void> _applyCommand(
    String action,
    Map<String, dynamic> data, {
    bool local = false,
  }) async {
    if (!local && !inRoom) return;
    final player = PlayerController.instance;
    final wasApplying = _applyingRemote;
    _applyingRemote = true;
    try {
      switch (action) {
        case 'play':
          // Sırada parça var ama hiçbir cihaz çalmaya başlamadıysa ilk
          // parçayı yükle; aksi halde player.play() boş kuyrukta sessiz kalır.
          if (player.current == null && _queue.isNotEmpty) {
            await _playerOp(
              () => player.playQueue(
                List<Track>.from(_queue),
                0,
                radio: false,
                useShufflePreference: false,
              ),
            );
          }
          await _playerOp(() => player.play());
          break;
        case 'pause':
          await _playerOp(() => player.pause());
          break;
        case 'next':
          if (_queue.isEmpty) {
            await _playerOp(() => player.next());
            break;
          }
          // Yerel player kuyruğu oda kuyruğundan eski olabilir (yeni eklenen
          // parçalar henüz yüklenmemiştir). Bu yüzden sırayı her seferinde
          // paylaşılan kuyruktan yeniden kurarak ilerleriz.
          final wasPlaying = player.playing;
          final current = _queueIndex(player);
          final target = current + 1 >= _queue.length ? 0 : current + 1;
          await _playerOp(
            () => player.playQueue(
              List<Track>.from(_queue),
              target,
              radio: false,
              useShufflePreference: false,
            ),
          );
          if (!wasPlaying && player.playing) {
            await _playerOp(() => player.pause());
          }
          break;
        case 'previous':
          if (_queue.isEmpty) {
            await _playerOp(() => player.previous());
            break;
          }
          final wasPlayingPrev = player.playing;
          final currentPrev = _queueIndex(player);
          final targetPrev = currentPrev <= 0 ? 0 : currentPrev - 1;
          await _playerOp(
            () => player.playQueue(
              List<Track>.from(_queue),
              targetPrev,
              radio: false,
              useShufflePreference: false,
            ),
          );
          if (!wasPlayingPrev && player.playing) {
            await _playerOp(() => player.pause());
          }
          break;
        case 'seek':
          final ms = (data['positionMs'] as num?)?.toInt();
          if (ms != null && ms >= 0) {
            await _playerOp(() => player.seek(Duration(milliseconds: ms)));
          }
          break;
        case 'play_at':
          if (_queue.isEmpty) break;
          final id = data['trackId']?.toString() ?? '';
          var index = (data['index'] as num?)?.toInt() ?? 0;
          final found = id.isEmpty
              ? -1
              : _queue.indexWhere((track) => track.id == id);
          if (found >= 0) index = found;
          index = index.clamp(0, _queue.length - 1);
          await _playerOp(
            () => player.playQueue(
              List<Track>.from(_queue),
              index,
              radio: false,
              useShufflePreference: false,
            ),
          );
          final ms = (data['positionMs'] as num?)?.toInt() ?? 0;
          if (ms > 0) {
            await _playerOp(() => player.seek(Duration(milliseconds: ms)));
          }
          break;
        case 'add':
          final raw = data['track'];
          if (raw is! Map) break;
          final track = Track.fromJson(Map<String, dynamic>.from(raw));
          if (track.id.isEmpty || _queue.length >= _queueLimit) break;
          if (_queue.any((item) => item.id == track.id)) break;
          _queue = List<Track>.unmodifiable([..._queue, track]);
          _queueRev++;
          break;
        case 'remove':
          final id = data['trackId']?.toString() ?? '';
          var index = (data['index'] as num?)?.toInt() ?? -1;
          if (id.isNotEmpty) {
            final found = _queue.indexWhere((track) => track.id == id);
            if (found >= 0) index = found;
          }
          if (index < 0 || index >= _queue.length) break;
          _queue = List<Track>.unmodifiable(
            List<Track>.from(_queue)..removeAt(index),
          );
          _queueRev++;
          break;
      }
    } catch (error) {
      if (kDebugMode) debugPrint('CT room command error: $error');
    } finally {
      _releaseApplyingRemote(wasApplying);
      notifyListeners();
    }
  }

  Future<void> _sendCommand(
    String action,
    Map<String, dynamic> data, {
    bool applyLocally = true,
  }) async {
    if (!inRoom) return;
    final command = buildCommand(
      id: commandId(_clientId),
      action: action,
      payload: data,
    );
    // Yayın önce: yerel medya yüklemesi uzayabilir (zayıf bağlantıda 20 sn).
    // Komutu bekletirse diğer cihazlar oynat/duraklat sinyalini alamaz.
    _publish('command', command);
    if (applyLocally) await _applyCommand(action, command, local: true);
    if (_isHost) _publishState(force: true);
  }

  /// Oda içindeki oynat/duraklat düğmesi. Her cihaz aynı komutu alır.
  Future<void> togglePlayback() async {
    final player = PlayerController.instance;
    if (!inRoom || !_autoSync) {
      await player.toggle();
      return;
    }
    await _sendCommand(player.playing ? 'pause' : 'play', const {});
  }

  Future<void> play() => _sendCommand('play', const {});
  Future<void> pause() => _sendCommand('pause', const {});
  Future<void> next() => _sendCommand('next', const {});
  Future<void> previous() => _sendCommand('previous', const {});

  Future<void> seekTo(Duration position) =>
      _sendCommand('seek', <String, dynamic>{
        'positionMs': position.inMilliseconds,
      });

  Future<void> playAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    await _sendCommand('play_at', <String, dynamic>{
      'index': index,
      'trackId': _queue[index].id,
    });
  }

  Future<void> addTrack(Track track) =>
      _sendCommand('add', <String, dynamic>{'track': track.toJson()});

  Future<void> _removedByHost() async {
    const message = 'Ev sahibi seni odadan çıkardı.';
    await _detach(publishBye: false);
    _clearRoom();
    _setBusy(false, message);
  }

  Future<void> _applyRemoteState(Map<String, dynamic> payload) async {
    // Eski/geciken state yeni parçayı geri almasın. Bu kontrol kuyruk
    // güncellenmeden önce yapılmalı; aksi halde UI eski sıraya döner.
    if (!isRemoteStateNewer(payload, _lastRemoteState)) return;

    // Önceki uygulama sürüyorsa en yeni durumu kuyruğa al; tick'ler arasında
    // kaybolmasın. `_lastRemoteState` yalnızca gerçekten uygulanınca güncellenir;
    // erken güncellenirse bekleyen paket kendisi "eski" sayılıp atılır.
    if (_applyingRemote) {
      _pendingRemoteState = payload;
      return;
    }
    _applyingRemote = true;
    try {
      _lastRemoteState = payload;
      final incoming = payload['queue'];
      List<Track> decoded = const <Track>[];
      if (incoming is List) {
        decoded = incoming
            .whereType<Map>()
            .map((item) => Track.fromJson(Map<String, dynamic>.from(item)))
            .where((track) => track.id.isNotEmpty)
            .take(_queueLimit)
            .toList();
        if (decoded.isNotEmpty) _queue = List<Track>.unmodifiable(decoded);
      }
      final incomingRev = _stateNumber(payload['queueRev']);
      if (incomingRev > _queueRev) _queueRev = incomingRev;
      final remote = payload['playback'];
      final remoteMap = remote is Map
          ? Map<String, dynamic>.from(remote)
          : <String, dynamic>{};
      if (remote is Map) _playback = remoteMap;
      if (payload['roomName'] is String) {
        _roomName = payload['roomName'] as String;
      }
      notifyListeners();

      if (!_autoSync || _isHost) return;

      final player = PlayerController.instance;
      final stopped = payload['stopped'] == true ||
          remoteMap['stopped'] == true ||
          (remoteMap['id']?.toString() ?? '').isEmpty;
      if (stopped) {
        // Host durduğunda joiner eski parçayı çalmaya devam etmesin.
        if (player.playing) await _playerOp(() => player.pause());
        _playback = null;
        notifyListeners();
        return;
      }

      final id = remoteMap['id']!.toString();
      final queue = decoded.isNotEmpty
          ? decoded
          : (_queue.isNotEmpty
              ? _queue
              : <Track>[Track.fromJson(remoteMap)]);
      final index = resolveStateIndex(queue, remoteMap);
      final shouldPlay = remoteMap['playing'] == true;

      // Aynı parça görünse bile hata varsa kaynak yeniden açılmalı. Shuffle
      // tercihi oda kuyruğuna uygulanmaz; yoksa her tick kuyruğu karıştırıp
      // parçayı baştan başlatıyordu.
      final needsReload = player.current?.id != id ||
          !_sameQueue(player.tracks, queue) ||
          player.error != null;
      if (needsReload) {
        await _playerOp(
          () => player.playQueue(
            queue,
            index,
            radio: false,
            useShufflePreference: false,
          ),
        );
      }
      final rawPosition = remoteMap['positionMs'];
      final sampled = rawPosition is num ? rawPosition.toInt() : null;
      if (sampled != null) {
        final sentAt = _stateNumber(payload['sentAt']);
        final target = syncTargetMs(
          positionMs: sampled,
          sentAt: sentAt,
          nowMs: DateTime.now().millisecondsSinceEpoch,
          playing: shouldPlay,
          offsetMs: _clockOffsetMs,
        );
        _correctDrift(
          localMs: player.position.inMilliseconds,
          targetMs: target,
          playing: shouldPlay,
        );
      }
      // toggle() yerine açık komut: backend henüz "playing" olmadan toggling
      // yanlış yöne gidebiliyordu.
      if (shouldPlay) {
        if (!player.playing) await _playerOp(() => player.play());
      } else if (player.playing) {
        await _playerOp(() => player.pause());
      }
    } catch (error) {
      if (kDebugMode) debugPrint('CT room state apply error: $error');
    } finally {
      _releaseApplyingRemote(false);
    }
  }

  /// Küçük kaymaları hız ayarıyla, büyük kaymaları seek ile düzeltir.
  /// Sürekli seek yapmak tamponu bozduğu için eşik ayrıldı.
  void _correctDrift({
    required int localMs,
    required int targetMs,
    required bool playing,
  }) {
    if (!playing) {
      _cancelRateCorrection();
      return;
    }
    final diffMs = localMs - targetMs;
    final diff = diffMs.abs();
    if (diff < 120) {
      _cancelRateCorrection();
      return;
    }
    if (diff > 1500) {
      _cancelRateCorrection();
      unawaited(
        PlayerController.instance.seek(Duration(milliseconds: targetMs)),
      );
      return;
    }
    // diff > 0: yerel konum öndeyse yavaşlat; < 0: yetişmek için hızlandır.
    final rate = (1 - (diffMs / 9000)).clamp(0.90, 1.10);
    unawaited(PlayerController.instance.setSpeed(rate));
    _rateTimer?.cancel();
    _rateTimer = Timer(const Duration(milliseconds: 1400), () {
      unawaited(PlayerController.instance.setSpeed(1));
    });
  }

  void _cancelRateCorrection() {
    _rateTimer?.cancel();
    _rateTimer = null;
  }

  void _onLocalPlayerChanged() {
    if (!_isHost || _applyingRemote) return;
    final now = DateTime.now();
    if (now.difference(_lastStatePublish) < const Duration(seconds: 2)) return;
    _publishState();
  }

  void _pruneMembers() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 18));
    _memberSeen.removeWhere((_, seen) => seen.isBefore(cutoff));
    final removed = _members.keys
        .where((id) => id != _clientId && !_memberSeen.containsKey(id))
        .toList();
    if (removed.isEmpty) return;
    final hostGone = removed.any((id) => _members[id]?.isHost == true);
    for (final id in removed) {
      _members.remove(id);
    }
    // Broker LWT teslim edilmediyse (ör. broker restart) host sessizce kaybolur.
    // 18 sn sonra kalan üyeler arasından deterministik seçim yapılır.
    if (hostGone && !_isHost) {
      final candidates = <String>{..._members.keys, _clientId};
      candidates.removeWhere((id) => removed.contains(id));
      if (candidates.isNotEmpty && candidates.reduce((a, b) => a.compareTo(b) <= 0 ? a : b) == _clientId) {
        _becomeHost();
      }
    }
    notifyListeners();
  }

  void _publishRaw(
    MqttServerClient client,
    String topic,
    Map<String, dynamic> envelope,
  ) {
    final builder = MqttClientPayloadBuilder()..addString(jsonEncode(envelope));
    try {
      client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
    } catch (_) {
      // Bağlantı kopmuşsa yayın hata verir. Komutları drop etmek yerine
      // sınırlı bir kuyruğa al; bağlantı gelince _flushQueuedPublishes gönderir.
      _queuedPublishes.add(envelope);
      if (_queuedPublishes.length > _maxQueuedPublishes) {
        _queuedPublishes.removeAt(0);
      }
    }
  }

  void _flushQueuedPublishes() {
    final client = _client;
    if (client == null || !inRoom || _queuedPublishes.isEmpty) return;
    final pending = List<Map<String, dynamic>>.from(_queuedPublishes);
    _queuedPublishes.clear();
    for (final envelope in pending) {
      // Kuyrukta uzun süre kalmış state/chat artık güncel değildir; yalnızca
      // komutlar ve katılım mesajları yeniden gönderilmeye değer.
      final age = DateTime.now().millisecondsSinceEpoch -
          ((envelope['at'] as num?)?.toInt() ?? 0);
      final type = envelope['type']?.toString() ?? '';
      final isCommand = type == 'command' || type == 'state_request';
      if (age > _commandTtl.inMilliseconds && !isCommand) continue;
      _publishRaw(client, _topic, envelope);
    }
  }

  /// Wi-Fi ve mobil veri için yayın sıklığını ayarlar. Mobil veride kalp
  /// atışları seyrekleşir; komutlar (play/pause/add) anında ve küçük kalır.
  Future<void> _watchConnectivity() async {
    if (_connectivityWatchStarted && _connectivitySub != null) return;
    _connectivityWatchStarted = true;
    try {
      final connectivity = Connectivity();
      final initial = await connectivity.checkConnectivity();
      _setConnectivity(initial);
      await _connectivitySub?.cancel();
      _connectivitySub =
          connectivity.onConnectivityChanged.listen((results) {
        _setConnectivity(results);
      });
    } catch (_) {
      // Plugin yoksa Wi-Fi varsayılır; oda trafiği eski hızda çalışmaya devam
      // eder. Başlatma bayrağı sıfırlanır ki sonraki katılım yeniden denesin.
      _mobileData = false;
      _connectivityWatchStarted = false;
    }
  }

  void _setConnectivity(List<ConnectivityResult> results) {
    final hasMobile = results.contains(ConnectivityResult.mobile);
    final hasWifi = results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
    final next = hasMobile && !hasWifi;
    final online = hasMobile || hasWifi || results.contains(ConnectivityResult.other);
    final wasOnline = _online;
    _online = online;
    // Açılışta relay'e ulaşılamadıysa ağ geri gelene kadar oda listesi
    // ölü kalıyordu. Yeniden bağlanmayı ağ değişimine bağlayarak kurtarırız.
    if (online && !wasOnline && _discoveryClient == null) {
      unawaited(startDiscovery());
    }
    if (next == _mobileData) {
      if (online != wasOnline) notifyListeners();
      return;
    }
    _mobileData = next;
    if (inRoom) _startStateTimer();
    // Keşif, odada olmasa bile açık kalır. Ağ değişince periyodu da
    // güncelle ki mobil veride gereksiz oda listesi trafiği oluşmasın.
    if (_discoveryClient != null) _startDiscoveryTimer();
    notifyListeners();
  }

  void _publish(String type, Map<String, dynamic> payload) {
    final client = _client;
    if (client == null || !inRoom) return;
    _publishRaw(client, _topic, {
      'room': _roomId,
      'channel': _channel(_roomId ?? '', _password),
      'type': type,
      'clientId': _clientId,
      'name': _displayName,
      'isHost': _isHost,
      'at': DateTime.now().millisecondsSinceEpoch,
      'payload': payload,
    });
  }

  /// Avatar verisi yalnızca değiştiğinde (ya da yeni katılım/isteke yanıt)
  /// gönderilir. Rutin 8 sn'lik presence paketi artık ~100 KB değil ~100 bayt;
  /// mobil veride trafik ve pil tüketimi belirgin düşer. Avatar olmayan
  /// presence'ta `avatarVersion` da gönderilmez; alıcı mevcut sürümü korur.
  void _publishPresence({bool includeAvatar = false}) {
    _memberSeen[_clientId] = DateTime.now();
    _putMember(RoomMember(
      clientId: _clientId,
      name: _displayName,
      avatar: _avatarDataUrl,
      avatarVersion: _avatarVersion,
      isHost: _isHost,
    ));
    final payload = <String, dynamic>{'roomName': _roomName};
    if (includeAvatar || _avatarDirty) {
      payload['avatar'] = _avatarDataUrl;
      payload['avatarVersion'] = _avatarVersion;
      _avatarDirty = false;
    }
    _publish('presence', payload);
  }

  void _startStateTimer() {
    _stateTimer?.cancel();
    _stateTimer = Timer.periodic(
      stateInterval(mobileData: _mobileData),
      (_) {
        _stateParity++;
        if (!_isHost) {
          // Misafirler host saatiyle arada kalan gecikmeyi periyodik ölçer.
          // Paket çok küçük; mobil veride daha seyrek tutulur.
          if (_stateParity % clockProbeTicks(mobileData: _mobileData) == 0) {
            _sendTimeProbe();
          }
          return;
        }
        // Sıra değişmediyse tam liste yerine yalnızca konum/çalma durumu.
        // Tam liste yalnızca tanımlı aralıklarla gönderilir; paket kaybında
        // katılımcılar kendini onarır, komutlar anında yayınlanır.
        final includeQueue =
            _stateParity % queueRefreshTicks(mobileData: _mobileData) == 0;
        _publishState(force: true, includeQueue: includeQueue);
      },
    );
  }

  void _publishState({bool force = false, bool? includeQueue}) {
    if (!_isHost) return;
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastStatePublish) < const Duration(seconds: 1)) {
      return;
    }
    _lastStatePublish = now;
    final player = PlayerController.instance;
    // Oda kuyruğu tek kaynaktır; çalar kuyruğu yalnızca yedek. Böylece iki
    // cihazın farklı sıraları nedeniyle index/parça ayrışması oluşmaz.
    final tracks = _queue.isNotEmpty ? _queue : player.tracks;
    var index = player.index;
    if (player.current != null && tracks.isNotEmpty) {
      final found = tracks.indexWhere((item) => item.id == player.current!.id);
      if (found >= 0) index = found;
    }
    final seq = ++_stateSeq;
    final sendQueue = includeQueue ??
        (_sentQueueRev != _queueRev || _stateParity % 8 == 0);
    _publish(
      'state',
      buildStatePayload(
        roomName: _roomName,
        tracks: tracks,
        index: index,
        positionMs: player.position.inMilliseconds,
        playing: player.playing,
        seq: seq,
        sentAt: now.millisecondsSinceEpoch,
        hostId: _clientId,
        queueRev: _queueRev,
        includeQueue: sendQueue,
        epoch: _hostEpoch,
      ),
    );
    if (sendQueue) _sentQueueRev = _queueRev;
  }

  // ---------------------------------------------------------------------
  // Oda keşfi (şifresiz metadata)
  // ---------------------------------------------------------------------

  /// Keşif kanalına bağlanır ve aktif oda listesini dinlemeye başlar.
  /// Birden çok kez çağrılabilir; yalnızca ilki bağlantı kurar.
  Future<bool> startDiscovery() async {
    if (_discoveryClient != null && _discoverySub != null) return true;
    if (_discoveryStarting) return false;
    _discoveryStarting = true;
    MqttServerClient? client;
    try {
      await init();
      // Keşif uygulama açılır açılmaz başlar; ağ türü oda dışındayken de
      // bilinmeli ki ilk yayın doğru periyotla yapılsın.
      unawaited(_watchConnectivity());
      // Oda kanalından ayrı, sabit bir istemci kimliği: self-filter ve
      // oda katılımı birbirini etkilemesin.
      final id = 'ct_${_clientId}_disc';
      client = MqttServerClient.withPort(
        RoomRelay.host,
        id,
        RoomRelay.port,
      );
      client.useWebSocket = true;
      client.websocketProtocols = MqttClientConstants.protocolsSingleDefault;
      client.keepAlivePeriod = 20;
      client.autoReconnect = true;
      client.logging(on: false);
      client.setProtocolV311();
      client.connectionMessage = MqttConnectMessage()
          .withClientIdentifier(id)
          .startClean();
      client.onDisconnected = () {
        _discoveryError = 'Oda listesi bağlantısı koptu, yeniden deneniyor…';
        notifyListeners();
      };
      client.onConnected = () {
        _discoveryError = '';
        notifyListeners();
      };

      final status = await client
          .connect()
          .timeout(const Duration(seconds: 15), onTimeout: () => null);
      final refused = status?.returnCode;
      if (refused != null &&
          refused != MqttConnectReturnCode.connectionAccepted) {
        _disposeDiscoveryClient(client);
        _discoveryError = _connectionMessage(refused);
        _scheduleDiscoveryRetry();
        notifyListeners();
        return false;
      }
      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        _disposeDiscoveryClient(client);
        _discoveryError = 'Oda listesi alınamadı: relay sunucusuna ulaşılamadı.';
        _scheduleDiscoveryRetry();
        notifyListeners();
        return false;
      }

      client.subscribe(RoomRelay.discoveryTopic, MqttQos.atLeastOnce);
      _discoverySub = client.updates?.listen(_onDiscoveryMessages);
      _discoveryClient = client;
      _discoveryFailures = 0;
      _discoveryRetryTimer?.cancel();
      _discoveryRetryTimer = null;
      _startDiscoveryTimer();
      _publishDiscovery();
      notifyListeners();
      return true;
    } catch (error) {
      if (client != null) _disposeDiscoveryClient(client);
      _discoveryError = 'Oda listesi alınamadı: ${_shortError(error)}';
      _scheduleDiscoveryRetry();
      notifyListeners();
      return false;
    } finally {
      _discoveryStarting = false;
    }
  }

  void _disposeDiscoveryClient(MqttServerClient client) {
    try {
      client.disconnect();
    } catch (_) {}
  }

  /// İlk açılışta relay down olsa bile oda listesi kendiliğinden geri gelir.
  /// Üstel geri çekilme ile 5 sn'den 2 dk'ya kadar seyreltilir.
  void _scheduleDiscoveryRetry() {
    if (!_online || _discoveryRetryTimer?.isActive == true) return;
    _discoveryFailures++;
    var seconds = 5;
    for (var i = 1; i < _discoveryFailures && seconds < 120; i++) {
      seconds *= 2;
    }
    if (seconds > 120) seconds = 120;
    _discoveryRetryTimer = Timer(Duration(seconds: seconds), () {
      _discoveryRetryTimer = null;
      if (_discoveryStarting || _discoveryClient != null) return;
      unawaited(startDiscovery());
    });
  }

  /// Keşif yayınını ağ türüne göre ayarlar. Wi-Fi'de 5 sn, mobil veride 10 sn.
  void _startDiscoveryTimer() {
    _discoveryTimer?.cancel();
    _discoveryTimer = Timer.periodic(
      discoveryInterval(mobileData: _mobileData),
      (_) {
        _pruneDiscovery();
        _publishDiscovery();
      },
    );
  }

  void stopDiscovery() {
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _discoveryRetryTimer?.cancel();
    _discoveryRetryTimer = null;
    _discoveryFailures = 0;
    _discoverySub?.cancel();
    _discoverySub = null;
    final client = _discoveryClient;
    _discoveryClient = null;
    if (client != null) {
      try {
        client.disconnect();
      } catch (_) {}
    }
  }

  void _onDiscoveryMessages(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final received in messages) {
      final publish = received.payload as MqttPublishMessage?;
      if (publish == null) continue;
      final raw = MqttPublishPayload.bytesToStringAsString(
        publish.payload.message,
      );
      Map<String, dynamic> envelope;
      try {
        envelope = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (envelope['clientId'] == _clientId) continue;
      final type = envelope['type']?.toString();
      final payload = envelope['payload'];
      if (payload is! Map) continue;
      final data = Map<String, dynamic>.from(payload);

      if (type == 'discovery_bye') {
        final code = normalizeCode('${data['code'] ?? ''}');
        final hostId = '${data['hostId'] ?? ''}';
        _discovered.removeWhere(
          (key, value) => value.code == code && value.hostId == hostId,
        );
        notifyListeners();
        continue;
      }
      if (type != 'discovery') continue;

      final room = RoomDiscovery.fromJson(data);
      if (room.code.isEmpty || room.memberCount < 1 || room.hostId.isEmpty) {
        continue;
      }
      _discovered['${room.code}_${room.hostId}'] = room;
      notifyListeners();
    }
  }

  void _publishDiscovery() {
    final client = _discoveryClient;
    if (client == null || !inRoom || !_isHost) return;
    _publishRaw(client, RoomRelay.discoveryTopic, {
      'type': 'discovery',
      'clientId': _clientId,
      'at': DateTime.now().millisecondsSinceEpoch,
      'payload': {
        'code': _roomId,
        'hostId': _clientId,
        'roomName': _roomName,
        // self zaten _publishPresence() ile _members içinde; +1 yapılırsa
        // oda listesinde kişi sayısı bir fazla görünür.
        'memberCount': _members.length,
        // Şifrenin kendisi hiç gönderilmez, yalnızca var olup olmadığı.
        'hasPassword': _password.isNotEmpty,
        'hostName': _displayName,
      },
    });
  }

  void _publishDiscoveryGone() {
    final client = _discoveryClient;
    final code = _roomId;
    if (client == null || code == null || !_isHost) return;
    _publishRaw(client, RoomRelay.discoveryTopic, {
      'type': 'discovery_bye',
      'clientId': _clientId,
      'at': DateTime.now().millisecondsSinceEpoch,
      'payload': {'code': code, 'hostId': _clientId},
    });
  }

  void _pruneDiscovery() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 25));
    final before = _discovered.length;
    _discovered.removeWhere((_, room) => room.seen.isBefore(cutoff));
    if (_discovered.length != before) notifyListeners();
  }

  // ---------------------------------------------------------------------

  void _clearRoom() {
    _roomId = null;
    _roomName = '';
    _password = '';
    _displayName = '';
    _isHost = false;
    // Odadan çıkınca eski avatarı ve sürümünü sıfırla; aksi halde yeni odaya
    // önceki odanın avatarı eski sürüm numarasıyla taşınır.
    _avatarDataUrl = '';
    _avatarVersion = 0;
    _remoteDataAllowed = false;
    _members.clear();
    _chat.clear();
    _reactions.clear();
    _memberSeen.clear();
    _queue = const [];
    _playback = null;
    _stateSeq = 0;
    _queueRev = 0;
    _sentQueueRev = -1;
    _clockOffsetMs = 0;
    _probeSend.clear();
    _seenCommands.clear();
    _queuedPublishes.clear();
    _lastRemoteState = null;
    _pendingRemoteState = null;
    _applyingRemote = false;
    _cancelRateCorrection();
  }

  @override
  void didChangeAppLifecycleState(flutter.AppLifecycleState state) {
    if (!inRoom) return;
    if (state == flutter.AppLifecycleState.resumed) {
      // Telefon uyandığında WebSocket çoğu zaman yeniden bağlanır; yerel
      // abonelik geri gelmezse diğer cihazın durumu 2-4 sn içinde gelmez.
      _publishPresence();
      if (_isHost) {
        _publishState(force: true);
      } else {
        _publish('state_request', const <String, dynamic>{});
        _sendTimeProbe();
      }
    } else if (state == flutter.AppLifecycleState.paused) {
      _cancelRateCorrection();
    }
  }

  Future<void> leave() async {
    await _detach(publishBye: true);
    // Keşif kanalı odadan bağımsız; odadan çıkınca boşa bağlı kalmasın.
    stopDiscovery();
    _clearRoom();
    _error = '';
    notifyListeners();
  }

  Future<void> _detach({required bool publishBye}) async {
    if (publishBye && inRoom) {
      _publish('bye', const {});
      _publishDiscoveryGone();
    }
    final ack = _ackCompleter;
    _ackCompleter = null;
    if (ack != null && !ack.isCompleted) ack.complete(false);

    await _messageSub?.cancel();
    _messageSub = null;
    _presenceTimer?.cancel();
    _presenceTimer = null;
    _stateTimer?.cancel();
    _stateTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    _rateTimer?.cancel();
    _rateTimer = null;
    unawaited(_connectivitySub?.cancel());
    _connectivitySub = null;
    _connectivityWatchStarted = false;
    flutter.WidgetsBinding.instance.removeObserver(this);
    PlayerController.instance.removeListener(_onLocalPlayerChanged);
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        client.disconnect();
      } catch (_) {}
    }
  }

  void _setBusy(bool value, String error) {
    _busy = value;
    _error = error;
    notifyListeners();
  }

  Future<void> sendChat(String text) async {
    final clean = text.trim();
    if (clean.isEmpty || !inRoom) return;
    final message = RoomMessage(
      id: '${_clientId}_${DateTime.now().millisecondsSinceEpoch}',
      clientId: _clientId,
      name: _displayName,
      text: clean,
      at: DateTime.now(),
    );
    _chat.add(message);
    if (_chat.length > 60) _chat.removeAt(0);
    _publish('chat', message.toJson());
    notifyListeners();
  }

  /// Gerçek avatarı (küçük JPEG dataUrl) presence ile yayınlar.
  /// İçerik değiştiğinde sürüm artar; aynı görsel tekrar gönderilmez.
  Future<bool> uploadAvatar(String dataUrl) async {
    final clean = dataUrl.trim();
    if (!clean.startsWith('data:image/jpeg;base64,')) {
      _error = 'Avatar sıkıştırılmış JPEG olmalı.';
      notifyListeners();
      return false;
    }
    if (clean.length > maxAvatarDataUrlChars) {
      _error = 'Avatar çok büyük (en fazla ~100KB).';
      notifyListeners();
      return false;
    }
    if (clean == _avatarDataUrl) return true;

    _avatarDataUrl = clean;
    _avatarVersion++;
    _avatarDirty = true;
    _members[_clientId] = RoomMember(
      clientId: _clientId,
      name: _displayName,
      avatar: clean,
      avatarVersion: _avatarVersion,
      isHost: _isHost,
    );
    _publishPresence();
    notifyListeners();
    return true;
  }

  /// Diğer cihazların avatar/oda bilgilerini görme onayı.
  Future<void> grantRemoteData() async {
    if (remoteDataAllowed) return;
    _remoteDataAllowed = true;
    _initialConsent = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_consentKey, true);
    // Mevcut üyelerin avatarlarını hemen alalım; sonraki presence zaten
    // yeni sürümü taşıyacak.
    _publish('hello', {'requestPresence': true});
    notifyListeners();
  }

  Future<void> renameRoom(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    _roomName = clean;
    _publishPresence();
    _publishState(force: true);
    _publishDiscovery();
    notifyListeners();
  }

  Future<void> setPassword(String password) async {
    final clean = normalizePassword(password);
    // Kanal girişte sabitlenir; oda içinde şifre değiştirilemez.
    if (inRoom) return;
    _password = clean;
    notifyListeners();
  }

  void setAutoSync(bool value) {
    final wasOff = !_autoSync;
    _autoSync = value;
    if (value && wasOff && !_isHost) {
      _publish('state_request', const <String, dynamic>{});
    }
    notifyListeners();
  }

  /// Sıradan çıkarma artık iki cihazda da kullanılabilir; komut tüm
  /// katılımcılara yayılır (eski sürümde yalnızca host yapabiliyordu).
  Future<void> removeFromQueue(int index) async {
    if (index < 0 || index >= _queue.length) return;
    await _sendCommand('remove', <String, dynamic>{
      'index': index,
      'trackId': _queue[index].id,
    });
  }

  Future<void> react(String emoji) async {
    if (!inRoom || emoji.isEmpty) return;
    _reactions[emoji] = (_reactions[emoji] ?? 0) + 1;
    _publish('reaction', {'emoji': emoji});
    notifyListeners();
  }

  Future<void> playFromQueue(int index) => playAt(index);

  /// Her iki cihaz da kendi kitaplığından odaya parça ekleyebilir.
  Future<void> addToQueue(Track track) => addTrack(track);

  Future<void> kick(String memberId) async {
    if (!_isHost || memberId.isEmpty || memberId == _clientId) return;
    _publish('kick', {'memberId': memberId});
    _members.remove(memberId);
    _memberSeen.remove(memberId);
    notifyListeners();
  }

  Future<void> transferHost(String memberId) async {
    if (!_isHost || !_members.containsKey(memberId)) return;
    _publish('host_transfer', {'memberId': memberId});
    _isHost = false;
    for (final entry in _members.entries.toList()) {
      _members[entry.key] =
          entry.value.copyWith(isHost: entry.key == memberId);
    }
    _stateTimer?.cancel();
    _stateTimer = null;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_detach(publishBye: false));
    stopDiscovery();
    super.dispose();
  }
}
