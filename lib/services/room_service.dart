import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import '../constants.dart';

enum RoomStatus { idle, creating, joining, playing }
enum RoomRole { owner, member }

class RoomService extends ChangeNotifier {
  RoomService._();
  static final RoomService instance = RoomService._();

  // Room state
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

  // Current room's playback state sync
  Song? _syncedSong;
  Song? get syncedSong => _syncedSong;

  Duration? _position;
  Duration? get position => _position;

  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;

  // Queue synced from room
  List<Song> _syncedQueue = [];
  List<Song> get syncedQueue => List.unmodifiable(_syncedQueue);

  int _syncedIndex = 0;
  int get syncedIndex => _syncedIndex;

  // Local playback overrides
  bool _localAutoplay = true;
  bool get localAutoplay => _localAutoplay;

  bool _localShuffle = false;
  bool get localShuffle => _localShuffle;

  // Use simple repeat state instead of RepeatMode enum
  String _localRepeat = 'off';
  String get localRepeat => _localRepeat;

  // Room settings
  int _memberCount = 0;
  int get memberCount => _memberCount;

  // Internal tracking
  Map<String, String> _memberNames = {};
  Map<String, String> _memberPhotos = {};

  // ─── Persistence keys ───
  static const String _roomIdKey = 'room_id';
  static const String _roomCodeKey = 'room_code';
  static const String _passwordKey = 'room_password';
  static const String _roleKey = 'room_role';
  static const String _profilePhotoKey = 'room_profile_photo';
  static const String _syncedSongKey = 'synced_song';
  static const String _syncedQueueKey = 'synced_queue';
  static const String _syncedIndexKey = 'synced_index';
  static const String _memberCountKey = 'member_count';
  static const String _isPlayingKey = 'is_playing';
  static const String _localAutoplayKey = 'local_autoplay';
  static const String _localShuffleKey = 'local_shuffle';
  static const String _localRepeatKey = 'local_repeat';
  static const String _memberNamesKey = 'member_names';
  static const String _memberPhotosKey = 'member_photos';

  // ─── Room Operations ───

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _status = RoomStatus.idle;
    _roomId = prefs.getString(_roomIdKey);
    _roomCode = prefs.getString(_roomCodeKey);
    _password = prefs.getString(_passwordKey);
    _role = RoomRole.values[prefs.getInt(_roleKey) ?? 0];
    _profilePhotoUrl = prefs.getString(_profilePhotoKey);
    // Queue and position
    _syncedQueue = _loadSongList(prefs.getString(_syncedQueueKey));
    _syncedIndex = prefs.getInt(_syncedIndexKey) ?? 0;
    _memberCount = prefs.getInt(_memberCountKey) ?? 0;
    _isPlaying = prefs.getBool(_isPlayingKey) ?? false;
    _localAutoplay = prefs.getBool(_localAutoplayKey) ?? true;
    _localShuffle = prefs.getBool(_localShuffleKey) ?? false;
    _localRepeat = prefs.getString(_localRepeatKey) ?? 'off';
    _memberNames = _loadMap(prefs.getString(_memberNamesKey));
    _memberPhotos = _loadMap(prefs.getString(_memberPhotosKey));
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    if (_roomId != null) {
      await prefs.setString(_roomIdKey, _roomId!);
    }
    if (_roomCode != null) {
      await prefs.setString(_roomCodeKey, _roomCode!);
    }
    if (_password != null) {
      await prefs.setString(_passwordKey, _password!);
    }
    await prefs.setInt(_roleKey, _role.index);
    if (_profilePhotoUrl != null) {
      await prefs.setString(_profilePhotoKey, _profilePhotoUrl!);
    }
    await prefs.setString(_syncedSongKey, _syncedSong != null ? jsonEncode(_syncedSong!.toJson()) : '{}');
    await prefs.setString(_syncedQueueKey, _saveSongList(_syncedQueue));
    await prefs.setInt(_syncedIndexKey, _syncedIndex);
    await prefs.setInt(_memberCountKey, _memberCount);
    await prefs.setBool(_isPlayingKey, _isPlaying);
    await prefs.setBool(_localAutoplayKey, _localAutoplay);
    await prefs.setBool(_localShuffleKey, _localShuffle);
    await prefs.setString(_localRepeatKey, _localRepeat);
    await prefs.setString(_memberNamesKey, _saveMap(_memberNames));
    await prefs.setString(_memberPhotosKey, _saveMap(_memberPhotos));
  }

  static Map<String, String> _loadMap(String? json) {
    if (json == null) return {};
    try { return Map<String, String>.from(jsonDecode(json)); } catch (_) { return {}; }
  }

  static String _saveMap(Map<String, String> map) {
    return map.isEmpty ? '' : jsonEncode(map);
  }

  static List<Song> _loadSongList(String? json) {
    if (json == null) return [];
    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) { return []; }
  }

  static String _saveSongList(List<Song> songs) {
    return songs.isEmpty ? '' : jsonEncode(songs.map((s) => s.toJson()).toList());
  }

  // ─── Create Room ───

  Future<void> createRoom({
    required String roomCode,
    String? password,
    String? profilePhotoUrl,
  }) async {
    _status = RoomStatus.creating;
    _roomId = DateTime.now().millisecondsSinceEpoch.toString();
    _roomCode = roomCode;
    _password = password;
    _role = RoomRole.owner;
    _profilePhotoUrl = profilePhotoUrl;
    _memberCount = 1;
    _memberNames[_roomId!] = 'Owner';
    _memberPhotos[_roomId!] = profilePhotoUrl ?? '';
    await _persist();
    _status = RoomStatus.idle;
    notifyListeners();
  }

  // ─── Join Room ───

  Future<bool> joinRoom({
    required String roomCode,
    required String password,
  }) async {
    _status = RoomStatus.joining;
    if (password.isNotEmpty && password != _password) {
      _status = RoomStatus.idle;
      return false;
    }

    _roomCode = roomCode;
    _password = password.isNotEmpty ? password : null;
    _roomId = 'room_$roomCode';
    _role = RoomRole.member;
    _memberCount = 2;
    _memberNames[_roomId!] = 'Member';
    _memberPhotos[_roomId!] = '';
    await _persist();
    _status = RoomStatus.idle;
    notifyListeners();
    return true;
  }

  // ─── Leave Room ───

  void leaveRoom() {
    _roomId = null;
    _roomCode = null;
    _password = null;
    _role = RoomRole.member;
    _profilePhotoUrl = null;
    _syncedQueue = [];
    _syncedIndex = 0;
    _memberCount = 0;
    _memberNames.clear();
    _memberPhotos.clear();
    _persist();
    notifyListeners();
  }

  // ─── Playback Sync ───

  void syncPlayback({
    required Song song,
    required Duration position,
    required bool isPlaying,
    required List<Song> queue,
    required int index,
  }) {
    _syncedSong = song;
    _position = position;
    _isPlaying = isPlaying;
    _syncedQueue = queue;
    _syncedIndex = index;
    _persist();
    notifyListeners();
  }

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

  // ─── Profile Photo ───

  void setProfilePhoto(String? url) {
    _profilePhotoUrl = url;
    if (_roomId != null) {
      _memberPhotos[_roomId!] = url ?? '';
    }
    _persist();
    notifyListeners();
  }

  // ─── Member management ───

  void setMemberName(String roomId, String name) {
    _memberNames[roomId] = name;
    _persist();
    notifyListeners();
  }

  void setMemberPhoto(String roomId, String? photoUrl) {
    _memberPhotos[roomId] = photoUrl ?? '';
    _persist();
    notifyListeners();
  }
}