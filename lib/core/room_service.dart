import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
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

class RoomService extends ChangeNotifier {
  RoomService._();

  static final RoomService instance = RoomService._();

  static const _clientIdKey = 'room_client_id';
  static const _consentKey = 'room_remote_data_consent';
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// Kabaca 100 KB JPEG için base64 karakter sınırı.
  static const int maxAvatarDataUrlChars = 140000;

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
  bool _applyingRemote = false;
  Completer<bool>? _ackCompleter;

  MqttServerClient? _discoveryClient;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _discoverySub;
  Timer? _discoveryTimer;
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

  /// Şifre davet bağlantısında taşınır; kopyalanan metin tek başına yeterli.
  String get inviteLink {
    final code = _roomId;
    if (code == null) return '';
    final base = 'cloudtune://room/$code';
    if (!hasPassword) return base;
    return '$base?p=${Uri.encodeComponent(_password)}';
  }

  String get roomPassword => _password;

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

    final connected = await _attach();
    if (!connected) {
      final message =
          _error.isEmpty ? 'Odaya bağlanılamadı.' : _error;
      _clearRoom();
      _setBusy(false, message);
      return RoomJoinResult.failed(message, RoomJoinFailure.connection);
    }

    PlayerController.instance.addListener(_onLocalPlayerChanged);
    _presenceTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _publishPresence();
      _pruneMembers();
    });
    _stateTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_isHost) _publishState(force: true);
    });
    _publishPresence();
    if (avatar.isNotEmpty) unawaited(uploadAvatar(avatar));
    if (_isHost) _publishState(force: true);

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

    _setBusy(false, '');
    return RoomJoinResult.success;
  }

  Future<bool> _attach() async {
    try {
      // Yeniden bağlanmada suffix değişmesin: aynı istemci kimliği korunur.
      final id = 'ct_$_clientId';
      final client = MqttServerClient.withPort(
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
        _error = '';
        notifyListeners();
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
        }
        notifyListeners();

      case 'ack':
        if (payloadMap['to'] == _clientId) {
          final completer = _ackCompleter;
          if (completer != null && !completer.isCompleted) {
            completer.complete(true);
          }
        }

      case 'bye':
        _members.remove(remoteId);
        _memberSeen.remove(remoteId);
        notifyListeners();

      case 'kick':
        if (payloadMap['memberId'] == _clientId) {
          unawaited(_removedByHost());
        }

      case 'host_transfer':
        if (payloadMap['memberId'] == remoteId) {
          for (final entry in _members.entries.toList()) {
            _members[entry.key] =
                entry.value.copyWith(isHost: entry.key == remoteId);
          }
          notifyListeners();
        }

      case 'state':
        if (payload is Map && !_isHost) {
          _applyRemoteState(Map<String, dynamic>.from(payload));
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

  Future<void> _removedByHost() async {
    const message = 'Ev sahibi seni odadan çıkardı.';
    await _detach(publishBye: false);
    _clearRoom();
    _setBusy(false, message);
  }

  Future<void> _applyRemoteState(Map<String, dynamic> payload) async {
    final incoming = payload['queue'];
    if (incoming is List) {
      final tracks = incoming
          .whereType<Map>()
          .map((item) => Track.fromJson(Map<String, dynamic>.from(item)))
          .where((track) => track.id.isNotEmpty)
          .toList();
      if (tracks.isNotEmpty) _queue = List<Track>.unmodifiable(tracks);
    }
    final remote = payload['playback'];
    if (remote is Map) _playback = Map<String, dynamic>.from(remote);
    if (payload['roomName'] is String) {
      _roomName = payload['roomName'] as String;
    }
    notifyListeners();

    if (_applyingRemote || !_autoSync || remote is! Map) return;
    final id = remote['id']?.toString() ?? '';
    if (id.isEmpty) return;

    final player = PlayerController.instance;
    _applyingRemote = true;
    try {
      if (player.current?.id != id) {
        var index = (remote['index'] as num?)?.toInt() ?? 0;
        if (_queue.isNotEmpty) {
          index = index.clamp(0, _queue.length - 1);
        } else {
          index = 0;
        }
        final queue = _queue.isNotEmpty
            ? _queue
            : [Track.fromJson(Map<String, dynamic>.from(remote))];
        await player.playQueue(queue, index, radio: false);
      }
      final positionMs = (remote['positionMs'] as num?)?.toInt();
      if (positionMs != null &&
          (player.position.inMilliseconds - positionMs).abs() > 5000) {
        await player.seek(Duration(milliseconds: positionMs));
      }
      final shouldPlay = remote['playing'] == true;
      if (shouldPlay != player.playing) await player.toggle();
    } catch (_) {
      // Sunucu durumu uygulanamazsa yerel çalma korunur.
    } finally {
      _applyingRemote = false;
    }
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
    for (final id in removed) {
      _members.remove(id);
    }
    notifyListeners();
  }

  void _publishRaw(
    MqttServerClient client,
    String topic,
    Map<String, dynamic> envelope,
  ) {
    final builder = MqttClientPayloadBuilder()..addString(jsonEncode(envelope));
    client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
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

  void _publishPresence() {
    _memberSeen[_clientId] = DateTime.now();
    _putMember(RoomMember(
      clientId: _clientId,
      name: _displayName,
      avatar: _avatarDataUrl,
      avatarVersion: _avatarVersion,
      isHost: _isHost,
    ));
    _publish('presence', {
      'roomName': _roomName,
      'avatar': _avatarDataUrl,
      'avatarVersion': _avatarVersion,
    });
  }

  void _publishState({bool force = false}) {
    if (!_isHost) return;
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastStatePublish) < const Duration(seconds: 2)) {
      return;
    }
    _lastStatePublish = now;
    final player = PlayerController.instance;
    final track = player.current;
    _publish('state', {
      'roomName': _roomName,
      'queue': _queue.map((track) => track.toJson()).toList(),
      'playback': track == null
          ? null
          : {
              ...track.toJson(),
              'index': player.index,
              'positionMs': player.position.inMilliseconds,
              'playing': player.playing,
            },
    });
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
    try {
      await init();
      // Oda kanalından ayrı, sabit bir istemci kimliği: self-filter ve
      // oda katılımı birbirini etkilemesin.
      final id = 'ct_${_clientId}_disc';
      final client = MqttServerClient.withPort(
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
        client.disconnect();
        _discoveryError = _connectionMessage(refused);
        notifyListeners();
        return false;
      }
      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        client.disconnect();
        _discoveryError = 'Oda listesi alınamadı: relay sunucusuna ulaşılamadı.';
        notifyListeners();
        return false;
      }

      client.subscribe(RoomRelay.discoveryTopic, MqttQos.atLeastOnce);
      _discoverySub = client.updates?.listen(_onDiscoveryMessages);
      _discoveryClient = client;
      _discoveryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _pruneDiscovery();
        _publishDiscovery();
      });
      _publishDiscovery();
      notifyListeners();
      return true;
    } catch (error) {
      _discoveryError = 'Oda listesi alınamadı: ${_shortError(error)}';
      notifyListeners();
      return false;
    } finally {
      _discoveryStarting = false;
    }
  }

  void stopDiscovery() {
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
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
        'memberCount': _members.length + 1,
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
    _members.clear();
    _chat.clear();
    _reactions.clear();
    _memberSeen.clear();
    _queue = const [];
    _playback = null;
  }

  Future<void> leave() async {
    await _detach(publishBye: true);
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
    _autoSync = value;
    notifyListeners();
  }

  Future<void> removeFromQueue(int index) async {
    if (!_isHost || index < 0 || index >= _queue.length) return;
    _queue = List<Track>.from(_queue)..removeAt(index);
    _publishState(force: true);
    notifyListeners();
  }

  Future<void> react(String emoji) async {
    if (!inRoom || emoji.isEmpty) return;
    _reactions[emoji] = (_reactions[emoji] ?? 0) + 1;
    _publish('reaction', {'emoji': emoji});
    notifyListeners();
  }

  Future<void> playFromQueue(int index) async {
    if (index < 0 || index >= _queue.length) return;
    final track = _queue[index];
    _playback = {
      ...track.toJson(),
      'index': index,
      'positionMs': 0,
      'playing': true,
    };
    notifyListeners();
    await PlayerController.instance.playQueue(
      List<Track>.from(_queue),
      index,
      radio: false,
    );
    _publishState(force: true);
  }

  Future<void> addToQueue(Track track) async {
    _queue = [..._queue, track];
    _publishState(force: true);
    notifyListeners();
  }

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
