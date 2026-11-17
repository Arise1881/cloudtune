import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Device-only user data: listening history, likes, playlists, search history
/// and playback preferences. Nothing is ever sent to a server.
class Library extends ChangeNotifier {
  Library._();

  static final Library instance = Library._();

  static const int _historyLimit = 60;
  static const int _searchHistoryLimit = 50;

  SharedPreferences? _prefs;

  final List<Track> _history = [];
  final Map<String, Track> _liked = {};
  final Map<String, List<Track>> _playlists = {};
  final List<String> _searchHistory = [];

  String? _avatarPath;
  bool _linkHandlerEnabled = true;
  bool _downloadToDevice = true;
  bool _radioEnabled = true;
  bool _ready = false;

  bool get ready => _ready;
  List<Track> get history => List.unmodifiable(_history);
  List<Track> get liked => List.unmodifiable(_liked.values);
  int get likedCount => _liked.length;
  String? get avatarPath => _avatarPath;
  bool get linkHandlerEnabled => _linkHandlerEnabled;
  bool get downloadToDevice => _downloadToDevice;
  bool get radioEnabled => _radioEnabled;

  List<String> get playlistNames => _playlists.keys.toList();
  List<Track> getPlaylist(String name) => _playlists[name] ?? const [];
  List<List<Track>> get allPlaylists =>
      _playlists.values.map((list) => List<Track>.unmodifiable(list)).toList();

  List<String> get searchHistory => List.unmodifiable(_searchHistory);

  /// Most listened-to artist, used as a personal radio seed.
  String? get topArtist {
    if (_history.isEmpty) return null;
    final counts = <String, int>{};
    for (final track in _history) {
      counts[track.artist] = (counts[track.artist] ?? 0) + 1;
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.first.key;
  }

  Future<void> init() async {
    if (_ready) return;
    try {
      _prefs = await SharedPreferences.getInstance();
      final prefs = _prefs!;

      _history
        ..clear()
        ..addAll(_decodeTracks(prefs.getString('ct.history')));

      _liked.clear();
      for (final track in _decodeTracks(prefs.getString('ct.liked'))) {
        _liked[track.id] = track;
      }

      _avatarPath = prefs.getString('ct.avatar');
      _linkHandlerEnabled = prefs.getBool('ct.linkHandler') ?? true;
      _downloadToDevice = prefs.getBool('ct.download') ?? true;
      _radioEnabled = prefs.getBool('ct.radio') ?? true;

      _restorePlaylists(prefs.getString('ct.playlists'));
      _restoreSearchHistory(prefs.getString('ct.searchHistory'));
    } catch (_) {
      // Unreadable storage: keep defaults and continue normally.
    }
    _ready = true;
    notifyListeners();
  }

  void _restorePlaylists(String? raw) {
    _playlists.clear();
    if (raw == null) return;
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return;
      data.forEach((key, value) {
        if (key is String && value is List) {
          _playlists[key] = _decodeTracks(jsonEncode(value));
        }
      });
    } catch (_) {}
  }

  void _restoreSearchHistory(String? raw) {
    _searchHistory.clear();
    if (raw == null) return;
    try {
      final data = jsonDecode(raw);
      if (data is List) {
        _searchHistory.addAll(
          data.whereType<String>().take(_searchHistoryLimit),
        );
      }
    } catch (_) {}
  }

  List<Track> _decodeTracks(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final data = jsonDecode(raw);
      if (data is! List) return const [];
      return data
          .whereType<Map<String, dynamic>>()
          .map(Track.fromJson)
          .where((track) => track.id.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveString(String key, String value) async {
    try {
      await _prefs?.setString(key, value);
    } catch (_) {}
  }

  Future<void> _removeKey(String key) async {
    try {
      await _prefs?.remove(key);
    } catch (_) {}
  }

  Future<void> _saveTracks(String key, List<Track> tracks) =>
      _saveString(key, jsonEncode(tracks.map((t) => t.toJson()).toList()));

  bool isLiked(String id) => _liked.containsKey(id);

  Future<void> toggleLike(Track track) async {
    if (_liked.remove(track.id) == null) {
      _liked[track.id] = track;
    }
    notifyListeners();
    await _saveTracks('ct.liked', _liked.values.toList());
  }

  Future<void> remember(Track track) async {
    _history.removeWhere((t) => t.id == track.id);
    _history.insert(0, track);
    if (_history.length > _historyLimit) {
      _history.removeRange(_historyLimit, _history.length);
    }
    notifyListeners();
    await _saveTracks('ct.history', _history);
  }

  Future<void> setAvatar(String? path) async {
    _avatarPath = path;
    notifyListeners();
    if (path == null) {
      await _removeKey('ct.avatar');
    } else {
      await _saveString('ct.avatar', path);
    }
  }

  Future<void> setLinkHandlerEnabled(bool value) async {
    _linkHandlerEnabled = value;
    notifyListeners();
    await _setBool('ct.linkHandler', value);
  }

  Future<void> setDownloadToDevice(bool value) async {
    _downloadToDevice = value;
    notifyListeners();
    await _setBool('ct.download', value);
  }

  Future<void> setRadioEnabled(bool value) async {
    _radioEnabled = value;
    notifyListeners();
    await _setBool('ct.radio', value);
  }

  Future<void> _setBool(String key, bool value) async {
    try {
      await _prefs?.setBool(key, value);
    } catch (_) {}
  }

  Future<void> createPlaylist(String name, List<Track> tracks) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    _playlists[clean] = List.unmodifiable(tracks);
    notifyListeners();
    await _saveString('ct.playlists', jsonEncode(_playlists));
  }

  Future<void> deletePlaylist(String name) async {
    _playlists.remove(name);
    notifyListeners();
    await _saveString('ct.playlists', jsonEncode(_playlists));
  }

  Future<void> addSearchHistory(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _searchHistory.remove(trimmed);
    _searchHistory.insert(0, trimmed);
    if (_searchHistory.length > _searchHistoryLimit) {
      _searchHistory.removeRange(_searchHistoryLimit, _searchHistory.length);
    }
    notifyListeners();
    await _saveString('ct.searchHistory', jsonEncode(_searchHistory));
  }

  Future<void> clearSearchHistory() async {
    _searchHistory.clear();
    notifyListeners();
    await _removeKey('ct.searchHistory');
  }

  Future<void> removeSearchHistory(int index) async {
    if (index < 0 || index >= _searchHistory.length) return;
    _searchHistory.removeAt(index);
    notifyListeners();
    await _saveString('ct.searchHistory', jsonEncode(_searchHistory));
  }
}
