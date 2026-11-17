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
  final String avatar;
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
      };
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

class RoomService extends ChangeNotifier {
  RoomService._();

  static final RoomService instance = RoomService._();

  static const _clientIdKey = 'room_client_id';
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  static String _clientId = '';

  static String get clientId => _clientId;

  String? _roomId;
  String _roomName = '';
  String _password = '';
  String _displayName = '';
  bool _isHost = false;
  bool _autoSync = true;
  bool _busy = false;
  String _error = '';

  final Map<String, RoomMember> _members = {};
  final List<RoomMessage> _chat = [];
  final Map<String, int> _reactions = {};
  List<Track> _queue = const [];
  Map<String, dynamic>? _playback;

  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _messageSub;
  Timer? _presenceTimer;
  Timer? _stateTimer;
  Timer? _pruneTimer;
  DateTime _lastStatePublish = DateTime.fromMillisecondsSinceEpoch(0);
  bool _applyingRemote = false;

  String? get roomId => _roomId;
  String get roomName => _roomName;
  bool get hasPassword => _password.isNotEmpty;
  bool get isHost => _isHost;
  bool get inRoom => _roomId != null;
  bool get busy => _busy;
  String get error => _error;
  bool get autoSync => _autoSync;

  List<RoomMember> get members {
    final list = _members.values.toList()
      ..sort((a, b) => (b.isHost ? 1 : 0) - (a.isHost ? 1 : 0));
    return List<RoomMember>.unmodifiable(list);
  }

  List<RoomMessage> get chat => List<RoomMessage>.unmodifiable(_chat);
  Map<String, int> get reactions => Map<String, int>.unmodifiable(_reactions);
  List<Track> get queue => List<Track>.unmodifiable(_queue);
  Map<String, dynamic>? get playback => _playback;

  String get inviteLink => _roomId == null ? '' : 'cloudtune://room/$_roomId';
  String get roomPassword => _password;

  static Future<void> init() async {
    if (_clientId.isNotEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_clientIdKey) ?? '';
    if (id.isEmpty) {
      final random = Random.secure();
      id =
          List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join();
      await prefs.setString(_clientIdKey, id);
    }
    _clientId = id;
  }

  static String _code() {
    final random = Random.secure();
    return List.generate(6, (_) => _alphabet[random.nextInt(_alphabet.length)])
        .join();
  }

  /// Kanal, kod ve şifrenin kısa özetinden oluşur. Böylece yalnızca kodu
  /// bilenler aynı odaya düşer; şifre asla relay'e gönderilmez.
  static String _channel(String code, String password) {
    var hash = 2166136261;
    for (final unit in password.codeUnits) {
      hash ^= unit;
      hash = (hash * 16777619) & 0xFFFFFFFF;
    }
    return '${code.toUpperCase()}-${hash.toRadixString(16).padLeft(8, '0')}';
  }

  String get _topic =>
      '${RoomRelay.topicPrefix}/${_channel(_roomId ?? '', _password)}/events';

  Future<bool> create({
    required String name,
    required String password,
    String avatar = '',
    String displayName = '',
  }) =>
      _enter(
        code: _code(),
        name: name,
        password: password,
        displayName: displayName,
        isHost: true,
      );

  Future<bool> join({
    required String code,
    required String password,
    String avatar = '',
    String displayName = '',
  }) =>
      _enter(
        code: code,
        name: 'Oda $code',
        password: password,
        displayName: displayName,
        isHost: false,
      );

  Future<bool> _enter({
    required String code,
    required String name,
    required String password,
    required String displayName,
    required bool isHost,
  }) async {
    final clean = code.trim().toUpperCase();
    if (clean.isEmpty) {
      _error = 'Oda kodu gerekli.';
      notifyListeners();
      return false;
    }

    await init();
    _setBusy(true, '');
    await _detach(publishBye: false);

    _roomId = clean;
    _roomName = name.trim().isEmpty ? 'Oda $clean' : name.trim();
    _password = password;
    _displayName =
        displayName.trim().isEmpty ? 'Dinleyici' : displayName.trim();
    _isHost = isHost;
    _members.clear();
    _chat.clear();
    _reactions.clear();
    _queue = const [];
    _playback = null;

    final connected = await _attach();
    if (!connected) {
      _roomId = null;
      _roomName = '';
      _password = '';
      _isHost = false;
      _setBusy(false, _error.isEmpty ? 'Odaya bağlanılamadı.' : _error);
      return false;
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
    if (_isHost) _publishState(force: true);
    _setBusy(false, '');
    return true;
  }

  Future<bool> _attach() async {
    try {
      final client = MqttServerClient.withPort(
        RoomRelay.host,
        'ct_${_clientId}_${DateTime.now().millisecondsSinceEpoch % 100000}',
        RoomRelay.port,
      );
      client.useWebSocket = true;
      client.websocketProtocols = MqttClientConstants.protocolsSingleDefault;
      client.keepAlivePeriod = 20;
      client.autoReconnect = true;
      client.logging(on: false);
      client.setProtocolV311();
      client.connectionMessage = MqttConnectMessage()
          .withClientIdentifier(
            'ct_${_clientId}_${DateTime.now().millisecondsSinceEpoch % 100000}',
          )
          .startClean();
      client.onDisconnected = () {
        if (!inRoom) return;
        _error = 'Bağlantı koptu, yeniden deneniyor…';
        notifyListeners();
      };
      client.onConnected = () {
        _error = '';
        notifyListeners();
      };

      final status = await client
          .connect()
          .timeout(const Duration(seconds: 15), onTimeout: () => null);
      if (status?.returnCode != MqttConnectReturnCode.connectionAccepted &&
          client.connectionStatus?.state != MqttConnectionState.connected) {
        client.disconnect();
        _error = 'Relay sunucusuna ulaşılamadı.';
        return false;
      }

      client.subscribe(_topic, MqttQos.atLeastOnce);
      _messageSub = client.updates?.listen(_onMessages);
      _client = client;
      return true;
    } catch (error) {
      _error = 'Bağlantı hatası: ${error.toString().split(' ').first}';
      return false;
    }
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
    final name = envelope['name']?.toString() ?? 'Dinleyici';
    final member = RoomMember(
      clientId: envelope['clientId']?.toString() ?? '',
      name: name,
      avatar: '',
      avatarVersion: 0,
      isHost: envelope['isHost'] == true,
    );

    switch (type) {
      case 'presence':
        _members[member.clientId] = member;
        _memberSeen[member.clientId] = DateTime.now();
        if (payload is Map && payload['roomName'] is String) {
          _roomName = payload['roomName'] as String;
        }
        notifyListeners();

      case 'bye':
        _members.remove(member.clientId);
        notifyListeners();

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
        if (payload is Map) {
          final emoji = payload['emoji']?.toString() ?? '';
          if (emoji.isNotEmpty) {
            _reactions[emoji] = (_reactions[emoji] ?? 0) + 1;
            notifyListeners();
          }
        }
    }
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

  final Map<String, DateTime> _memberSeen = {};

  void _publish(String type, Map<String, dynamic> payload) {
    final client = _client;
    if (client == null || !inRoom) return;
    final envelope = {
      'room': _roomId,
      'channel': _channel(_roomId ?? '', _password),
      'type': type,
      'clientId': _clientId,
      'name': _displayName,
      'isHost': _isHost,
      'at': DateTime.now().millisecondsSinceEpoch,
      'payload': payload,
    };
    final builder = MqttClientPayloadBuilder()..addString(jsonEncode(envelope));
    client.publishMessage(_topic, MqttQos.atLeastOnce, builder.payload!);
  }

  void _publishPresence() {
    _memberSeen[_clientId] = DateTime.now();
    _publish('presence', {'roomName': _roomName});
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

  Future<void> leave() async {
    await _detach(publishBye: true);
    _roomId = null;
    _roomName = '';
    _password = '';
    _displayName = '';
    _isHost = false;
    _members.clear();
    _chat.clear();
    _reactions.clear();
    _queue = const [];
    _playback = null;
    _error = '';
    notifyListeners();
  }

  Future<void> _detach({required bool publishBye}) async {
    if (publishBye && inRoom) _publish('bye', const {});
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

  Future<bool> uploadAvatar(String dataUrl) async {
    _members[_clientId] = RoomMember(
      clientId: _clientId,
      name: _displayName,
      avatar: dataUrl,
      avatarVersion: 0,
      isHost: _isHost,
    );
    notifyListeners();
    return dataUrl.isNotEmpty;
  }

  Future<void> renameRoom(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    _roomName = clean;
    _publishPresence();
    _publishState(force: true);
    notifyListeners();
  }

  Future<void> setPassword(String password) async {
    // Kanal adresi girişte sabitlenir; şifre değişikliği yeni oda gerektirir.
    if (!inRoom) _password = password;
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

  Future<void> kick(String memberId) async {}
  Future<void> transferHost(String memberId) async {}

  @override
  void dispose() {
    unawaited(_detach(publishBye: false));
    super.dispose();
  }
}
