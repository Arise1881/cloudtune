import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Sıralı, düzenlenebilir yerel çalma listesi.
///
/// Eski `ct.playlists` (name -> tracks) verisi bu modele migrate edilir;
/// yeni veri `ct.playlist_metas` altında tutulur.
class PlaylistMeta {
  PlaylistMeta({
    required this.id,
    required this.name,
    required this.tracks,
    required this.createdAt,
    this.source = 'user',
    this.artistId,
  });

  String id;
  String name;
  List<Track> tracks;
  DateTime createdAt;

  /// 'user' | 'artist' | 'search'
  String source;

  /// Sanatçı listelerinde hangi sanatçıya ait olduğunu belirtir.
  String? artistId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tracks': tracks.map((t) => t.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
        'source': source,
        'artistId': artistId,
      };

  factory PlaylistMeta.fromJson(Map<String, dynamic> json) => PlaylistMeta(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        tracks: (json['tracks'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(Track.fromJson)
            .toList(),
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        source: json['source'] as String? ?? 'user',
        artistId: json['artistId'] as String?,
      );
}

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

  /// Sıralı liste artifact'ı. Eski getter'lar `_playlists` üzerinden buna
  /// yansıtılır; iki ayrı kaynak tutulmaz.
  final List<PlaylistMeta> _metas = [];
  final Map<String, List<Track>> _playlists = {};
  final List<String> _searchHistory = [];

  String _avatarPath = '';
  int _avatarVersion = 0;
  int _idCounter = 0;

  int _repeatMode = 0;
  bool _shuffleEnabled = false;

  bool _linkHandlerEnabled = true;
  bool _downloadToDevice = true;
  bool _radioEnabled = true;
  bool _ready = false;

  bool get ready => _ready;
  List<Track> get history => List.unmodifiable(_history);
  List<Track> get liked => List.unmodifiable(_liked.values);
  int get likedCount => _liked.length;

  /// Versiyonlu dosya yolu; her `setAvatar` çağrısında değişir, böylece
  /// `FileImage` cache key'i yenilenir. Avatar yoksa boş string.
  String get avatarPath => _avatarPath;
  int get avatarVersion => _avatarVersion;

  /// 0 = kapalı, 1 = tümü, 2 = tek parça.
  int get repeatMode => _repeatMode;
  bool get shuffleEnabled => _shuffleEnabled;

  bool get linkHandlerEnabled => _linkHandlerEnabled;
  bool get downloadToDevice => _downloadToDevice;
  bool get radioEnabled => _radioEnabled;

  /// Eski name -> tracks görünümü. Yeni veri de buraya yansıtılır.
  Map<String, List<Track>> get playlists => Map.unmodifiable(_playlists);
  List<String> get playlistNames => _playlists.keys.toList();
  List<Track> getPlaylist(String name) => _playlists[name] ?? const [];
  List<List<Track>> get allPlaylists =>
      _playlists.values.map((list) => List<Track>.unmodifiable(list)).toList();

  /// Tüm sıralı listeler (kullanıcı + sanatçı + arama).
  List<PlaylistMeta> get playlistMetas => List.unmodifiable(_metas);

  /// Yalnızca sanatçı çalma listeleri (`source == 'artist'`).
  List<PlaylistMeta> get artistPlaylists =>
      List.unmodifiable(_metas.where((m) => m.source == 'artist'));

  PlaylistMeta? playlistById(String id) {
    for (final meta in _metas) {
      if (meta.id == id) return meta;
    }
    return null;
  }

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

      _avatarVersion = prefs.getInt('ct.avatar_version') ?? 0;
      String? storedAvatar = prefs.getString('ct.avatar');
      if (_avatarVersion > 0) {
        try {
          final dir = await getApplicationDocumentsDirectory();
          storedAvatar = '${dir.path}/room_avatar_$_avatarVersion.jpg';
        } catch (_) {
          // Dizin alınamazsa kayıtlı yol kullanılmaya devam eder.
        }
      }
      _avatarPath = storedAvatar ?? '';

      // Tekrar/shuffle tek kaynaktan okunur: PlayerController aynı anahtarları
      // kullanır. Eski int tabanlı 'ct.repeat_mode' yalnızca geriye dönük
      // uyumluluk için fallback olarak okunur.
      final storedMode = prefs.getString('ct.repeatMode');
      _repeatMode = switch (storedMode) {
        'all' => 1,
        'one' => 2,
        _ => prefs.getInt('ct.repeat_mode') ?? 0,
      };
      _shuffleEnabled = prefs.getBool('ct.shuffle') ?? false;

      _linkHandlerEnabled = prefs.getBool('ct.linkHandler') ?? true;
      _downloadToDevice = prefs.getBool('ct.download') ?? true;
      _radioEnabled = prefs.getBool('ct.radio') ?? true;

      _restoreMetas(prefs.getString('ct.playlist_metas'));
      _migrateLegacyPlaylists(prefs.getString('ct.playlists'));
      _syncLegacyPlaylists();
      await _persistMetas();

      _restoreSearchHistory(prefs.getString('ct.searchHistory'));
    } catch (_) {
      // Unreadable storage: keep defaults and continue normally.
    }
    _ready = true;
    notifyListeners();
  }

  void _restoreMetas(String? raw) {
    _metas.clear();
    if (raw == null) return;
    try {
      final data = jsonDecode(raw);
      if (data is! List) return;
      for (final item in data) {
        if (item is! Map<String, dynamic>) continue;
        final meta = PlaylistMeta.fromJson(item);
        if (meta.id.isEmpty || meta.name.isEmpty) continue;
        _metas.add(meta);
      }
    } catch (_) {}
  }

  /// `ct.playlists` -> `ct.playlist_metas` tek seferlik geçiş.
  void _migrateLegacyPlaylists(String? raw) {
    if (raw == null) return;
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return;
      data.forEach((key, value) {
        if (key is! String || key.isEmpty || value is! List) return;
        if (_metas.any((m) => m.name == key)) return;
        _metas.add(PlaylistMeta(
          id: _newId('legacy'),
          name: key,
          tracks: _decodeTracks(jsonEncode(value)),
          createdAt: DateTime.now(),
          source: 'user',
        ));
      });
    } catch (_) {}
  }

  void _syncLegacyPlaylists() {
    _playlists
      ..clear()
      ..addEntries(_metas.map((m) => MapEntry<String, List<Track>>(m.name, m.tracks)));
  }

  String _newId([String prefix = 'pl']) =>
      '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';

  Future<void> _commitMetas() async {
    _syncLegacyPlaylists();
    notifyListeners();
    await _persistMetas();
  }

  Future<void> _persistMetas() async {
    await _saveString(
      'ct.playlist_metas',
      jsonEncode(_metas.map((m) => m.toJson()).toList()),
    );
    await _saveString('ct.playlists', jsonEncode(_playlists));
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

  Future<void> _saveInt(String key, int value) async {
    try {
      await _prefs?.setInt(key, value);
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

  /// Seçilen dosyayı versiyonlu bir adla kopyalar; eski dosyalar silinmez.
  /// Dönen `avatarPath` her çağrıda değiştiği için UI cache'i yenilenir.
  Future<void> setAvatar(String? path) async {
    if (path == null || path.isEmpty) {
      _avatarPath = '';
      notifyListeners();
      await _removeKey('ct.avatar');
      return;
    }

    final source = File(path);
    if (source.existsSync()) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final version = _avatarVersion + 1;
        final target = '${dir.path}/room_avatar_$version.jpg';
        await source.copy(target);
        _avatarVersion = version;
        _avatarPath = target;
        notifyListeners();
        await _saveString('ct.avatar', target);
        await _saveInt('ct.avatar_version', version);
        return;
      } catch (_) {
        // Kopyalama başarısızsa ham yolu kullan, yine de bildir.
      }
    }

    _avatarPath = path;
    notifyListeners();
    await _saveString('ct.avatar', path);
  }

  Future<void> setRepeatMode(int value) async {
    _repeatMode = value.clamp(0, 2);
    notifyListeners();
    await _saveString(
      'ct.repeatMode',
      const <String>['off', 'all', 'one'][_repeatMode],
    );
  }

  Future<void> setShuffleEnabled(bool value) async {
    _shuffleEnabled = value;
    notifyListeners();
    await _setBool('ct.shuffle', value);
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

  /// Eski API: isim aynıysa parçaları güncellenir, yoksa yeni liste eklenir.
  Future<void> createPlaylist(String name, List<Track> tracks) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    final existing = _metas.where((m) => m.name == clean).toList();
    if (existing.isNotEmpty) {
      existing.first.tracks = List.unmodifiable(tracks);
    } else {
      _metas.add(PlaylistMeta(
        id: _newId(),
        name: clean,
        tracks: List.unmodifiable(tracks),
        createdAt: DateTime.now(),
        source: 'user',
      ));
    }
    await _commitMetas();
  }

  /// Hem yeni id hem eski isim ile çağrılabilir (eski UI uyumluluğu).
  Future<void> deletePlaylist(String idOrName) async {
    final byId = playlistById(idOrName);
    if (byId != null) {
      _metas.remove(byId);
    } else {
      _metas.removeWhere((m) => m.name == idOrName);
    }
    await _commitMetas();
  }

  Future<void> addToPlaylist(String id, Track track) async {
    final meta = playlistById(id);
    if (meta == null) return;
    if (meta.tracks.any((t) => t.id == track.id)) return;
    meta.tracks.add(track);
    await _commitMetas();
  }

  Future<void> removeFromPlaylist(String id, int index) async {
    final meta = playlistById(id);
    if (meta == null || index < 0 || index >= meta.tracks.length) return;
    meta.tracks.removeAt(index);
    await _commitMetas();
  }

  /// Flutter `ReorderableListView.onReorder` ham indeksleriyle çağrılır:
  /// `oldIndex < newIndex` ise `newIndex` bir azaltılır.
  Future<void> reorderPlaylist(String id, int oldIndex, int newIndex) async {
    final meta = playlistById(id);
    if (meta == null ||
        oldIndex < 0 ||
        oldIndex >= meta.tracks.length ||
        newIndex < 0) {
      return;
    }
    var target = newIndex;
    if (oldIndex < target) target -= 1;
    if (target < 0) target = 0;
    if (target >= meta.tracks.length) target = meta.tracks.length - 1;
    final track = meta.tracks.removeAt(oldIndex);
    meta.tracks.insert(target, track);
    await _commitMetas();
  }

  Future<void> renamePlaylist(String id, String name) async {
    final meta = playlistById(id);
    final clean = name.trim();
    if (meta == null || clean.isEmpty) return;
    meta.name = clean;
    await _commitMetas();
  }

  Future<void> saveArtistPlaylist(
    String artistId,
    String name,
    List<Track> tracks,
  ) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    // Aynı sanatçı tekrar kaydedilirse yeni kart eklemek yerine mevcut
    // listenin parçalarını güncelle; id ve oluşturma tarihi korunur.
    final existing = _metas.cast<PlaylistMeta?>().firstWhere(
          (m) => m!.source == 'artist' && m.artistId == artistId,
          orElse: () => null,
        );
    if (existing != null) {
      existing.tracks = List<Track>.of(tracks);
      existing.name = clean;
    } else {
      _metas.add(PlaylistMeta(
        id: _newId('artist'),
        name: clean,
        tracks: List<Track>.of(tracks),
        createdAt: DateTime.now(),
        source: 'artist',
        artistId: artistId,
      ));
    }
    await _commitMetas();
  }

  Future<void> saveSearchPlaylist(String name, List<Track> tracks) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    final existing = _metas.cast<PlaylistMeta?>().firstWhere(
          (m) => m!.source == 'search' && m.name == clean,
          orElse: () => null,
        );
    if (existing != null) {
      existing.tracks = List<Track>.of(tracks);
    } else {
      _metas.add(PlaylistMeta(
        id: _newId('search'),
        name: clean,
        tracks: List<Track>.of(tracks),
        createdAt: DateTime.now(),
        source: 'search',
      ));
    }
    await _commitMetas();
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
