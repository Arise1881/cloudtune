import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Cihazda saklanan kisisel veriler: dinleme gecmisi, begeniler,
/// oda avatarı ve kullanıcı tercihleri. Sunucuya hicbir sey gonderilmez.
class Library extends ChangeNotifier {
  Library._();
  static final Library instance = Library._();

  static const int _historyLimit = 60;

  SharedPreferences? _prefs;

  final List<Track> _history = [];
  final Map<String, Track> _liked = {};

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

  Future<void> init() async {
    if (_ready) return;
    try {
      _prefs = await SharedPreferences.getInstance();
      _history
        ..clear()
        ..addAll(_decodeList(_prefs!.getString('ct.history')));
      _liked.clear();
      for (final t in _decodeList(_prefs!.getString('ct.liked'))) {
        _liked[t.id] = t;
      }
      _avatarPath = _prefs!.getString('ct.avatar');
      _linkHandlerEnabled = _prefs!.getBool('ct.linkHandler') ?? true;
      _downloadToDevice = _prefs!.getBool('ct.download') ?? true;
      _radioEnabled = _prefs!.getBool('ct.radio') ?? true;
    } catch (_) {
      // Depolama okunamazsa uygulama varsayilanlarla calismaya devam eder.
    }
    _ready = true;
    notifyListeners();
  }

  List<Track> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final data = jsonDecode(raw);
      if (data is! List) return const [];
      return data
          .whereType<Map<String, dynamic>>()
          .map(Track.fromJson)
          .where((t) => t.id.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveList(String key, List<Track> tracks) async {
    try {
      await _prefs?.setString(
        key,
        jsonEncode(tracks.map((t) => t.toJson()).toList()),
      );
    } catch (_) {}
  }

  bool isLiked(String id) => _liked.containsKey(id);

  Future<void> toggleLike(Track track) async {
    if (_liked.remove(track.id) == null) {
      _liked[track.id] = track;
    }
    notifyListeners();
    await _saveList('ct.liked', _liked.values.toList());
  }

  Future<void> remember(Track track) async {
    _history.removeWhere((t) => t.id == track.id);
    _history.insert(0, track);
    if (_history.length > _historyLimit) {
      _history.removeRange(_historyLimit, _history.length);
    }
    notifyListeners();
    await _saveList('ct.history', _history);
  }

  /// Dinleme gecmisine gore kisisel tohum: en son dinlenen sanatci.
  String? get topArtist {
    if (_history.isEmpty) return null;
    final counts = <String, int>{};
    for (final t in _history) {
      counts[t.artist] = (counts[t.artist] ?? 0) + 1;
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.first.key;
  }

  Future<void> setAvatar(String? path) async {
    _avatarPath = path;
    notifyListeners();
    try {
      if (path == null) {
        await _prefs?.remove('ct.avatar');
      } else {
        await _prefs?.setString('ct.avatar', path);
      }
    } catch (_) {}
  }

  Future<void> setLinkHandlerEnabled(bool value) async {
    _linkHandlerEnabled = value;
    notifyListeners();
    try {
      await _prefs?.setBool('ct.linkHandler', value);
    } catch (_) {}
  }

  Future<void> setDownloadToDevice(bool value) async {
    _downloadToDevice = value;
    notifyListeners();
    try {
      await _prefs?.setBool('ct.download', value);
    } catch (_) {}
  }

  Future<void> setRadioEnabled(bool value) async {
    _radioEnabled = value;
    notifyListeners();
    try {
      await _prefs?.setBool('ct.radio', value);
    } catch (_) {}
  }
}
