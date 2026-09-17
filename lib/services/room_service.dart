import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:typed_data/typed_buffers.dart';

import '../models/song.dart';
import 'player_service.dart';

enum RoomStatus { idle, connecting, creating, joining, playing, error }
enum RoomRole { owner, member }

/// Gerçek oda senkronu: herkese açık MQTT broker'ı üzerinden (broker.emqx.io)
/// oda ortakları anlık çalma durumunu paylaşır. Oda kodu = konu adı.
/// Kimlik doğrulama yok — demo amaçlı, uygun şifreli oda için kendi broker'ınızı
/// kullanabilirsiniz (konu, broker adresi ile aynıdır).
class RoomService extends ChangeNotifier {
  RoomService._();
  static final RoomService instance = RoomService._();

  static const String _brokerHost = 'broker.emqx.io';
  static const int _brokerPort = 1883;
  static const String _topicPrefix = 'melody/rooms/';

  MqttClient? _mqtt;
  Timer? _heartbeat;

  RoomStatus _status = RoomStatus.idle;
  RoomStatus get status => _status;

  String? _roomId;
  String? get roomId => _roomId;

  String? _roomCode;
  String? get roomCode => _roomCode;

  String? _password;
  String? get password => _password;

  RoomRole _role = RoomRole.member;
  RoomRole get role => _role;

  String? _profilePhotoUrl;
  String? get profilePhotoUrl => _profilePhotoUrl;

  String? _displayName;
  String? get displayName => _displayName;

  bool _connected = false;
  bool get connected => _connected;

  bool _applyingRemote = false;
  bool get applyingRemote => _applyingRemote;

  String? _error;
  String? get error => _error;

  // Oda üyeleri (kendisi hariç): pid -> (isim, fotoğraf)
  final Map<String, ({String name, String photo})> _members = {};
  Map<String, ({String name, String photo})> get members =>
      Map.unmodifiable(_members);

  int get memberCount => _members.length + 1;

  // Yerel playback üstü override'lar (oda kapalıyken uygulanır)
  bool _localAutoplay = true;
  bool get localAutoplay => _localAutoplay;
  bool _localShuffle = false;
  bool get localShuffle => _localShuffle;
  String _localRepeat = 'off';
  String get localRepeat => _localRepeat;

  final String _pid =
      'p${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}'
      '${Random().nextInt(0xFFFF).toRadixString(16)}';

  // ─── Persistence keys ───
  static const String _roomIdKey = 'room_id';
  static const String _roomCodeKey = 'room_code';
  static const String _passwordKey = 'room_password';
  static const String _roleKey = 'room_role';
  static const String _profilePhotoKey = 'room_profile_photo';
  static const String _displayNameKey = 'room_display_name';
  static const String _localAutoplayKey = 'local_autoplay';
  static const String _localShuffleKey = 'local_shuffle';
  static const String _localRepeatKey = 'local_repeat';

  // ─── Oda kodları ───

  /// Rastgele 5 haneli oda kodu üretir.
  static String generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random();
    return List.generate(5, (_) => chars[r.nextInt(chars.length)]).join();
  }

  static String normalizeCode(String code) =>
      code.trim().toUpperCase().replaceAll(RegExp(r'[^0-9A-Z]'), '');

  String get _topic {
    final code = _roomCode ?? '';
    return '$_topicPrefix$code';
  }

  // ─── Yaşam döngüsü ───

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _roomId = prefs.getString(_roomIdKey);
    _roomCode = prefs.getString(_roomCodeKey);
    _password = prefs.getString(_passwordKey);
    _role = RoomRole.values[(prefs.getInt(_roleKey) ?? 1).clamp(0, 1)];
    _profilePhotoUrl = prefs.getString(_profilePhotoKey);
    _displayName = prefs.getString(_displayNameKey);
    _localAutoplay = prefs.getBool(_localAutoplayKey) ?? true;
    _localShuffle = prefs.getBool(_localShuffleKey) ?? false;
    _localRepeat = prefs.getString(_localRepeatKey) ?? 'off';
    // Önceden odadaysak yeniden bağlan
    if (_roomId != null && _roomCode != null) {
      unawaited(_connect());
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    if (_roomId != null) await prefs.setString(_roomIdKey, _roomId!);
    if (_roomCode != null) await prefs.setString(_roomCodeKey, _roomCode!);
    if (_password != null) await prefs.setString(_passwordKey, _password!);
    if (_displayName != null) {
      await prefs.setString(_displayNameKey, _displayName!);
    }
    await prefs.setInt(_roleKey, _role.index);
    if (_profilePhotoUrl != null) {
      await prefs.setString(_profilePhotoKey, _profilePhotoUrl!);
    }
    await prefs.setBool(_localAutoplayKey, _localAutoplay);
    await prefs.setBool(_localShuffleKey, _localShuffle);
    await prefs.setString(_localRepeatKey, _localRepeat);
  }

  // ─── Oda kur / katıl ───

  /// Yeni oda kurar ve MQTT bağlantısını açar.
  Future<bool> createRoom({
    String? roomCode,
    String? password,
    String? profilePhotoUrl,
    String? displayName,
  }) async {
    _status = RoomStatus.connecting;
    _error = null;
    notifyListeners();
    try {
      final code = normalizeCode(roomCode ?? generateCode());
      if (code.isEmpty) {
        throw const FormatException('Geçersiz oda kodu');
      }
      _roomId = _pid;
      _roomCode = code;
      _password = password?.isNotEmpty == true ? password : null;
      _role = RoomRole.owner;
      _profilePhotoUrl = profilePhotoUrl;
      _displayName = (displayName?.trim().isNotEmpty == true)
          ? displayName!.trim()
          : 'Sahibi';
      await _connect();
      await _persist();
      _publishPresence('join');
      _publishHello();
      _status = RoomStatus.playing;
      _startHeartbeat();
      notifyListeners();
      return true;
    } catch (e) {
      _status = RoomStatus.error;
      _error = 'Oda kurulamadı: $e';
      notifyListeners();
      return false;
    }
  }

  /// Var olan odaya katılır (kod eşleşmesinde şifre kontrolü MQTT'de yoktur;
  /// aynı kod konusunu bilen herkes odaya girebilir — kısıtlama).
  Future<bool> joinRoom({
    required String roomCode,
    required String password,
    String? profilePhotoUrl,
    String? displayName,
  }) async {
    _status = RoomStatus.connecting;
    _error = null;
    notifyListeners();
    try {
      final code = normalizeCode(roomCode);
      if (code.isEmpty) {
        throw const FormatException('Geçersiz oda kodu');
      }
      _roomId = _pid;
      _roomCode = code;
      _password = password.isNotEmpty ? password : null;
      _role = RoomRole.member;
      _profilePhotoUrl = profilePhotoUrl;
      _displayName = (displayName?.trim().isNotEmpty == true)
          ? displayName!.trim()
          : 'Dinleyici';
      await _connect();
      await _persist();
      _publishPresence('join');
      // Mevcut çalma durumunu iste (diğer üyeler state mesajıyla yanıtlar)
      _publishHello();
      _status = RoomStatus.playing;
      _startHeartbeat();
      notifyListeners();
      return true;
    } catch (e) {
      _status = RoomStatus.error;
      _error = 'Odaya katılınamadı: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> leaveRoom() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    if (_connected && _roomCode != null) {
      try {
        _publishPresence('leave');
      } catch (_) {}
    }
    await _disconnect();
    _roomId = null;
    _roomCode = null;
    _password = null;
    _role = RoomRole.member;
    _profilePhotoUrl = null;
    _members.clear();
    _status = RoomStatus.idle;
    notifyListeners();
    _clearPersistedState();
  }

  // ─── MQTT bağlantısı ───

  Future<void> _connect() async {
    await _disconnect();
    final topic = _topic;
    final client = MqttServerClient(_brokerHost, 'melody$_pid',
        maxConnectionAttempts: 3);
    client.port = _brokerPort;
    client.keepAlivePeriod = 30;
    client.autoReconnect = false;
    client.onDisconnected = () {
      _connected = false;
      if (_roomId != null) {
        _status = RoomStatus.connecting;
        notifyListeners();
        // Bağlantı koptu — otomatik yeniden dene
        _reconnectRetry();
      }
    };
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier('melody$_pid')
        .startClean()
        .withWillTopic('$topic/status/$_pid')
        .withWillMessage('exit')
        .withWillQos(MqttQos.atMostOnce)
        .withWillRetain();

    await client.connect();
    if (client.connectionStatus!.state != MqttConnectionState.connected) {
      throw Exception('Broker bağlantısı reddedildi');
    }
    _mqtt = client;
    _connected = true;

    client.subscribe(topic, MqttQos.atMostOnce);
    client.subscribe('$topic/status/#', MqttQos.atMostOnce);
    client.updates!.listen(_onMessage);

    // Basit durum mesajı: hayatta olduğumuzu duyur
    _publishPresence('join');
  }

  bool _reconnecting = false;

  void _reconnectRetry() {
    if (_reconnecting || _roomId == null) return;
    _reconnecting = true;
    Timer(const Duration(seconds: 4), () async {
      _reconnecting = false;
      if (_roomId == null) return;
      try {
        await _connect();
        _status = RoomStatus.playing;
        _publishHello();
        notifyListeners();
      } catch (_) {
        _reconnectRetry();
      }
    });
  }

  Future<void> _disconnect() async {
    _reconnecting = false;
    try {
      _mqtt?.disconnect();
    } catch (_) {}
    _mqtt = null;
    _connected = false;
  }

  // ─── Mesajlaşma ───

  void _publish(String payload) {
    final client = _mqtt;
    final topic = _topic;
    if (client == null || !_connected || topic.isEmpty) return;
    client.publishMessage(topic, MqttQos.atMostOnce,
        Uint8Buffer()..addAll(utf8.encode(payload)));
  }

  void _publishPresence(String op) {
    try {
      _publish(jsonEncode({
        't': 'member',
        'op': op,
        'pid': _pid,
        'name': _displayName ?? 'Misafir',
        'photo': _profilePhotoUrl ?? '',
      }));
    } catch (_) {}
  }

  void _publishHello() {
    try {
      _publish(jsonEncode({'t': 'hello', 'pid': _pid}));
    } catch (_) {}
  }

  /// Mevcut çalma durumunu odaya yayınlar (yalnız oda sahibi yayınlar;
  /// üyeler yalnız dinler — aksi halde iki taraf birlikte durumu override eder).
  void publishFromPlayer() {
    if (_role != RoomRole.owner) return;
    final topic = _topic;
    if (_mqtt == null || !_connected || topic.isEmpty) return;
    final player = PlayerService.instance;
    final current = player.current;
    if (current == null) return;
    _publish(jsonEncode({
      't': 'state',
      'pid': _pid,
      'song': current.toJson(),
      'queue': player.queue.map((s) => s.toJson()).toList(),
      'idx': player.index,
      'pos': player.position.inMilliseconds,
      'playing': player.isPlaying,
      // Sahibin çözdüğü akış URL'si: üyeye ilet — üye akış çözemezse bile ses.
      'stream': player.currentStreamUrl,
    }));
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 6), (_) {
      publishFromPlayer();
    });
  }

  void _onMessage(List<MqttReceivedMessage<MqttMessage>> events) {
    for (final event in events) {
      try {
        final payload = event.payload as MqttPublishMessage;
        final raw = utf8.decode(payload.payload.message);
        if (raw == 'exit') {
          _handleMemberLeave(event.topic);
          continue;
        }
        final msg = jsonDecode(raw) as Map<String, dynamic>;
        _handleMessage(msg);
      } catch (_) {}
    }
  }

  void _handleMessage(Map<String, dynamic> msg) {
    final type = msg['t'] as String?;
    final pid = msg['pid'] as String?;
    if (type == null || pid == null || pid == _pid) return;

    switch (type) {
      case 'member':
        final op = msg['op'] as String?;
        if (op == 'join') {
          _members[pid] = (
            name: (msg['name'] as String?) ?? 'Misafir',
            photo: (msg['photo'] as String?) ?? '',
          );
          // Yeni gelen olduğunda durumumuzu bir kez gönder
          Future.delayed(const Duration(milliseconds: 600), () {
            if (_members.containsKey(pid)) publishFromPlayer();
          });
        } else if (op == 'leave') {
          _members.remove(pid);
        }
        notifyListeners();
      case 'hello':
        // Yeni üye durumumuzu istedi — gönder
        Future.delayed(const Duration(milliseconds: 400), () {
          if (_members.containsKey(pid)) publishFromPlayer();
        });
      case 'state':
        _handleRemoteState(msg);
      case 'cmd':
        _handleRemoteCmd(msg);
    }
  }

  void _handleMemberLeave(String topic) {
    final seg = topic.split('/');
    if (seg.isEmpty) return;
    final pid = seg.last;
    if (_members.remove(pid) != null) {
      notifyListeners();
    }
  }

  void _handleRemoteState(Map<String, dynamic> msg) {
    Song? song;
    List<Song> queue = [];
    int idx = 0;
    try {
      final s = msg['song'] as Map<String, dynamic>?;
      if (s != null) song = Song.fromJson(s);
      if (msg['queue'] is List) {
        queue = (msg['queue'] as List)
            .whereType<Map<String, dynamic>>()
            .map(Song.fromJson)
            .toList();
      }
      idx = (msg['idx'] as num?)?.toInt() ?? 0;
    } catch (_) {}
    if (song == null) return;

    _applyingRemote = true;
    PlayerService.instance.applyRoomState(
      songs: queue.isNotEmpty ? queue : [song],
      index: idx,
      position: Duration(milliseconds: (msg['pos'] as num?)?.toInt() ?? 0),
      playing: (msg['playing'] as bool?) ?? false,
      stream: (msg['stream'] as String?)?.isNotEmpty == true
          ? (msg['stream'] as String)
          : null,
    );
    // Yayın geri dönüşünü engelle: kısa süre mutik
    Future.delayed(const Duration(milliseconds: 400), () {
      _applyingRemote = false;
    });
    notifyListeners();
  }

  void _handleRemoteCmd(Map<String, dynamic> msg) {
    final op = msg['op'] as String?;
    if (op == null) return;
    _applyingRemote = true;
    final p = PlayerService.instance;
    switch (op) {
      case 'play':
        p.roomPlayPause(play: true);
      case 'pause':
        p.roomPlayPause(play: false);
      case 'toggle':
        p.roomPlayPause(play: null);
      case 'next':
        p.roomSkip(forward: true);
      case 'prev':
        p.roomSkip(forward: false);
      case 'seek':
        final ms = (msg['pos'] as num?)?.toInt();
        if (ms != null) p.roomSeek(Duration(milliseconds: ms));
    }
    Future.delayed(const Duration(milliseconds: 400), () {
      _applyingRemote = false;
    });
    notifyListeners();
  }

  // ─── Uzaktan komutları PlayerService yürütür ───

  void sendCommand(String op, {int positionMs = 0}) {
    _publish(jsonEncode({
      't': 'cmd',
      'pid': _pid,
      'op': op,
      'pos': positionMs,
    }));
    // Lokal olarak da uygula (oynatma görevlisi dinlerken aynı aksiyon)
    PlayerService.instance.localCommand(op, positionMs: positionMs);
  }

  // ─── Yerel tercihler ───

  void setAutoplay(bool value) {
    _localAutoplay = value;
    _persist();
    notifyListeners();
  }

  void setShuffle(bool value) {
    _localShuffle = value;
    _persist();
    notifyListeners();
  }

  void setRepeat(String value) {
    _localRepeat = value;
    _persist();
    notifyListeners();
  }

  // ─── Profil fotoğrafı ───

  void setProfilePhoto(String? url) {
    _profilePhotoUrl = url;
    _publishPresence('join');
    _persist();
    notifyListeners();
  }

  void setDisplayName(String name) {
    _displayName = (name.trim().isEmpty) ? 'Misafir' : name.trim();
    _publishPresence('join');
    _persist();
    notifyListeners();
  }

  Future<void> _clearPersistedState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_roomIdKey);
    await prefs.remove(_roomCodeKey);
    await prefs.remove(_passwordKey);
    await prefs.remove(_roleKey);
    await prefs.remove(_profilePhotoKey);
  }
}