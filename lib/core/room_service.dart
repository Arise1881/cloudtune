import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library.dart';
import 'models.dart';
import 'player_controller.dart';

/// Odada bulunan bir dinleyici (yerel modda yalnızca bu cihaz).
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
}

/// Oda sohbeti mesajı.
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
}

/// Cihaz üzerinde çalışan yerel oda.
///
/// Oda kimliği zaman damgasından üretilir; üyeler ve çalma sırası yalnızca
/// bu cihazda tutulur. Sohbet, reaksiyon ve çoklu cihaz senkronizasyonu
/// harici bir sunucu gerektirir; bu sınıf ağ üzerinden istek göndermez.
class RoomService extends ChangeNotifier {
  RoomService._();

  static final RoomService instance = RoomService._();

  static const _clientIdKey = 'room_client_id';

  static String _clientId = '';

  /// Cihazda kalıcı saklanan istemci kimliği.
  static String get clientId => _clientId;

  String? _roomId;
  String _roomName = '';
  bool _hasPassword = false;
  bool _isHost = false;
  String _displayName = '';
  String _avatar = '';
  int _avatarVersion = 0;
  List<Track> _queue = const [];
  Map<String, dynamic>? _playback;

  String? get roomId => _roomId;
  String get roomName => _roomName;
  bool get hasPassword => _hasPassword;
  bool get isHost => _isHost;
  bool get inRoom => _roomId != null;
  bool get busy => false;
  String get error => '';

  /// Yerel kullanıcıyı tek üye olarak sunar; cihaz sayısı bire eşittir.
  List<RoomMember> get members {
    if (!inRoom) return const [];
    return [
      RoomMember(
        clientId: clientId,
        name: _displayName.isEmpty ? 'Sen' : _displayName,
        avatar: Library.instance.avatarPath ?? _avatar,
        avatarVersion: _avatarVersion,
        isHost: _isHost,
      ),
    ];
  }

  /// Yerel modda sunucuya bağlı sohbet bulunmaz.
  List<RoomMessage> get chat => const [];

  List<Track> get queue => List.unmodifiable(_queue);

  Map<String, dynamic>? get playback => _playback;

  static Future<void> init() async {
    if (_clientId.isNotEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_clientIdKey) ?? '';
    if (id.isEmpty) {
      final random = Random.secure();
      id = List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join();
      await prefs.setString(_clientIdKey, id);
    }
    _clientId = id;
  }

  Future<bool> create({
    required String name,
    required String password,
    String avatar = '',
    String displayName = '',
  }) async {
    await init();
    _roomId = 'local_${DateTime.now().millisecondsSinceEpoch}';
    _roomName = name.trim().isEmpty ? 'Yerel Oda' : name.trim();
    _hasPassword = password.isNotEmpty;
    _isHost = true;
    _displayName = displayName.trim();
    _avatar = avatar;
    _avatarVersion = 0;
    _queue = const [];
    _playback = null;
    notifyListeners();
    return true;
  }

  /// Harici bir odaya katılmak sunucu gerektirir; yerel modda desteklenmez.
  Future<bool> join({
    required String code,
    required String password,
    String avatar = '',
    String displayName = '',
  }) async {
    return false;
  }

  Future<void> leave() async {
    _roomId = null;
    _roomName = '';
    _hasPassword = false;
    _isHost = false;
    _displayName = '';
    _avatar = '';
    _avatarVersion = 0;
    _queue = const [];
    _playback = null;
    notifyListeners();
  }

  /// Sohbet sunucu gerektirir; yerel modda mesaj gönderilmez.
  Future<void> sendChat(String text) async {}

  /// Avatarı yalnızca yerel oda durumuna işler; ağa gönderim yapılmaz.
  Future<bool> uploadAvatar(String dataUrl) async {
    if (dataUrl.isEmpty) return false;
    _avatar = dataUrl;
    _avatarVersion++;
    notifyListeners();
    return true;
  }

  Future<void> renameRoom(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    _roomName = clean;
    notifyListeners();
  }

  Future<void> setPassword(String password) async {
    _hasPassword = password.isNotEmpty;
    notifyListeners();
  }

  Future<void> removeFromQueue(int index) async {
    if (index < 0 || index >= _queue.length) return;
    final next = List<Track>.from(_queue)..removeAt(index);
    _queue = next;
    notifyListeners();
  }

  /// Reaksiyonlar sunucu gerektirir; yerel modda kaydedilmez.
  Future<void> react(String emoji) async {}

  Future<void> playFromQueue(int index) async {
    if (index < 0 || index >= _queue.length) return;
    final track = _queue[index];
    _playback = {
      'id': track.id,
      'title': track.title,
      'artist': track.artist,
      'index': index,
    };
    notifyListeners();
    await PlayerController.instance.playQueue(
      List<Track>.from(_queue),
      index,
      radio: false,
    );
  }

  Future<void> addToQueue(Track track) async {
    _queue = [..._queue, track];
    notifyListeners();
  }

  /// Yalnızca yerel üye bulunduğu için atma işlemi yapılmaz.
  Future<void> kick(String memberId) async {}

  /// Yalnızca yerel üye bulunduğu için sahiplik devri yapılmaz.
  Future<void> transferHost(String memberId) async {}
}
