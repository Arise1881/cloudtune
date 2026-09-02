import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../constants.dart';
import '../models/song.dart';

/// Favoriler, çalma listeleri, indirme kayıtları ve son çalınanları
/// JSON dosyasında saklayan merkezi depo.
class LibraryStore extends ChangeNotifier {
  LibraryStore._();

  static final LibraryStore instance = LibraryStore._();

  List<Song> _favorites = [];
  Map<String, Song> _downloads = {};
  Map<String, List<Song>> _playlists = {};
  List<Song> _recents = [];

  File? _file;

  List<Song> get favorites => List.unmodifiable(_favorites);
  List<Song> get downloads => _downloads.values.toList()
    ..sort((a, b) => b.downloadedAtMs.compareTo(a.downloadedAtMs));
  Map<String, List<Song>> get playlists =>
      Map.unmodifiable(_playlists.map((k, v) => MapEntry(k, List<Song>.from(v))));
  List<Song> get recents => List.unmodifiable(_recents);

  bool isFavorite(String id) => _favorites.any((s) => s.id == id);
  bool isDownloaded(String id) => _downloads.containsKey(id);
  Song? downloadedSong(String id) => _downloads[id];

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/$libraryFileName');
    if (await _file!.exists()) {
      try {
        final data =
            jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        _favorites = Song.listFromJson(jsonEncode(data['favorites'] ?? []));
        _recents = Song.listFromJson(jsonEncode(data['recents'] ?? []));
        _downloads = ((data['downloads'] as Map<String, dynamic>?) ?? {})
            .map((k, v) => MapEntry(k, Song.fromJson(v as Map<String, dynamic>)));
        _playlists = ((data['playlists'] as Map<String, dynamic>?) ?? {})
            .map((k, v) => MapEntry(
                k, Song.listFromJson(jsonEncode(v as List<dynamic>))));
      } catch (_) {
        // Bozuk dosya: sıfırla.
      }
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    if (_file == null) return;
    try {
      await _file!.writeAsString(jsonEncode({
        'favorites': jsonDecode(Song.listToJson(_favorites)),
        'recents': jsonDecode(Song.listToJson(_recents)),
        'downloads': _downloads.map((k, v) => MapEntry(k, v.toJson())),
        'playlists': _playlists
            .map((k, v) => MapEntry(k, jsonDecode(Song.listToJson(v)))),
      }));
    } catch (e) {
      debugPrint('Library persist hatası: $e');
    }
  }

  void toggleFavorite(Song song) {
    if (isFavorite(song.id)) {
      _favorites.removeWhere((s) => s.id == song.id);
    } else {
      _favorites.insert(0, song);
    }
    _persist();
    notifyListeners();
  }

  void addDownload(Song song) {
    _downloads[song.id] = song.copyWith(downloadedAtMs: DateTime.now().millisecondsSinceEpoch);
    _persist();
    notifyListeners();
  }

  void removeDownload(String id) {
    _downloads.remove(id);
    _persist();
    notifyListeners();
  }

  void clearDownloads() {
    _downloads.clear();
    _persist();
    notifyListeners();
  }

  bool createPlaylist(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || _playlists.containsKey(trimmed)) return false;
    _playlists[trimmed] = [];
    _persist();
    notifyListeners();
    return true;
  }

  void deletePlaylist(String name) {
    _playlists.remove(name);
    _persist();
    notifyListeners();
  }

  void addToPlaylist(String name, Song song) {
    final list = _playlists.putIfAbsent(name, () => []);
    if (!list.any((s) => s.id == song.id)) list.add(song);
    _persist();
    notifyListeners();
  }

  void removeFromPlaylist(String name, String songId) {
    _playlists[name]?.removeWhere((s) => s.id == songId);
    _persist();
    notifyListeners();
  }

  void pushRecent(Song song) {
    _recents.removeWhere((s) => s.id == song.id);
    _recents.insert(0, song);
    if (_recents.length > 20) _recents = _recents.sublist(0, 20);
    _persist();
  }

  Future<int> downloadsSizeBytes() async {
    var total = 0;
    for (final song in _downloads.values) {
      final path = song.localPath;
      if (path == null) continue;
      try {
        total += await File(path).length();
      } catch (_) {}
    }
    return total;
  }
}
