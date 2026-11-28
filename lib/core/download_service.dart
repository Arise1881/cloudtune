import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library.dart';
import 'models.dart';
import 'youtube_service.dart';

/// Sanatçı/arama gibi bir kaynaktan toplu kaydedilen parça grubu.
class DownloadGroup {
  DownloadGroup({
    required this.id,
    required this.name,
    required List<String> trackIds,
    required this.createdAt,
  }) : _trackIds = List<String>.unmodifiable(trackIds);

  /// Kalıcı grup anahtarı (ör. `artist:UC...` / `search:...`).
  final String id;

  /// Kullanıcıya gösterilen grup adı.
  final String name;

  final List<String> _trackIds;

  final DateTime createdAt;

  List<String> get trackIds => _trackIds;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'trackIds': _trackIds,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory DownloadGroup.fromJson(Map<String, dynamic> json) => DownloadGroup(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        trackIds: (json['trackIds'] as List? ?? const <dynamic>[])
            .map((item) => item.toString())
            .where((item) => item.isNotEmpty)
            .toList(),
        createdAt: json['createdAt'] is num
            ? DateTime.fromMillisecondsSinceEpoch(
                (json['createdAt'] as num).toInt(),
              )
            : DateTime.now(),
      );
}

/// Parçaları cihaza kaydeder. Oynatma kopyası HER ZAMAN uygulama
/// belgelerinde tutulur; Android'de isteğe bağlı MediaStore kopyası yalnızca
/// galeri görünürlüğü içindir ve asla oynatma yolu olarak kullanılmaz.
class DownloadService extends ChangeNotifier {
  DownloadService._();

  static final DownloadService instance = DownloadService._();

  static const MethodChannel _saver = MethodChannel('cloudtune/saver');
  static const String _storageKey = 'ct.downloads';
  static const String _groupsKey = 'ct.download_groups';

  /// Toplu indirmede aynı anda açık tutulan istek sayısı.
  static const int _maxParallel = 3;

  /// Eski `.m4a` kayıtları korunur; yeni indirmeler MIME/itag'e göre uzantı alır.
  static const List<String> _extensions = <String>['.webm', '.m4a', '.mp3'];

  final Map<String, double> _progress = <String, double>{};
  final Map<String, String> _saved = <String, String>{};
  final Map<String, Track> _savedTracks = <String, Track>{};
  final Set<String> _failures = <String>{};
  final Map<String, String> _failureReason = <String, String>{};
  final Map<String, Track> _failedTracks = <String, Track>{};
  final Map<String, DownloadGroup> _groups = <String, DownloadGroup>{};
  final Set<String> _cancelled = <String>{};
  final Set<String> _cancelledByUser = <String>{};
  final Map<String, http.Client> _activeClients = <String, http.Client>{};
  final Map<String, Completer<void>> _cancelSignals = <String, Completer<void>>{};

  /// `savedPathOf` senkron dosya araması yapabilsin diye belgeler dizini önbelleği.
  String? _libraryDir;

  Future<void>? _initFuture;

  Future<void> init() => _initFuture ??= _load();

  bool isDownloading(String id) => _progress.containsKey(id);

  double progressOf(String id) => _progress[id] ?? 0;

  /// Kayıtlı yolu döndürür; yalnızca bilinen yola bakmaz, tüm desteklenen
  /// uzantılar arasında da arar (eski sürümlerden kalan dosyalar dahil).
  String? savedPathOf(String id) {
    final known = _saved[id];
    if (known != null && File(known).existsSync()) return known;

    final base = _libraryDir;
    if (base != null && id.isNotEmpty) {
      final dir = Directory('$base/CloudTune');
      if (dir.existsSync()) {
        for (final entity in dir.listSync()) {
          if (entity is! File) continue;
          final name = entity.path.split(RegExp(r'[\\/]')).last;
          for (final ext in _extensions) {
            if (!name.endsWith('-$id$ext')) continue;
            _saved[id] = entity.path;
            return entity.path;
          }
        }
      }
    }

    // Bilinen yol artık yoksa çağırana geçersiz bir yol vermeyelim.
    return null;
  }

  int get activeCount => _progress.length;

  /// Negatif değer onarım botu için hata işaretidir.
  Map<String, double> get downloadProgress => {
        ..._progress,
        for (final id in _failures) id: -1,
      };

  List<Track> get savedTracks => List<Track>.unmodifiable(_savedTracks.values);

  Set<String> get failureIds => Set.unmodifiable(_failures);

  /// `failureIds` ile aynı anahtarları kullanan hata nedenleri.
  Map<String, String> get failureReasons =>
      Map<String, String>.unmodifiable(_failureReason);

  /// Kalıcı sanatçı/arama grupları.
  Map<String, DownloadGroup> get groups =>
      Map<String, DownloadGroup>.unmodifiable(_groups);

  String? failureReason(String id) => _failureReason[id];

  Track? failedTrack(String id) => _failedTracks[id];

  void forgetFailure(String id) {
    _failures.remove(id);
    _failureReason.remove(id);
    _failedTracks.remove(id);
    notifyListeners();
  }

  void cancelDownload(String id) {
    if (!_progress.containsKey(id)) return;
    _cancelled.add(id);
    _cancelledByUser.add(id);
    _cancelSignals[id]?.complete();
    _activeClients[id]?.close();
    notifyListeners();
  }

  Future<T> _raceCancel<T>(String id, Future<T> future) {
    final signal = _cancelSignals.putIfAbsent(id, () => Completer<void>());
    if (signal.isCompleted) throw StateError('download-cancelled');
    return Future.any<T>(<Future<T>>[
      future,
      signal.future.then<T>((_) => throw StateError('download-cancelled')),
    ]);
  }

  Future<void> _load() async {
    var changed = false;
    try {
      _libraryDir = (await getApplicationDocumentsDirectory()).path;
    } catch (_) {}

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final data = jsonDecode(raw);
        if (data is List) {
          for (final item in data) {
            if (item is! Map<String, dynamic>) {
              changed = true;
              continue;
            }
            final track = Track.fromJson(
              Map<String, dynamic>.from(item['track'] as Map? ?? const {}),
            );
            final path = item['path']?.toString();
            if (track.id.isEmpty || path == null || path.isEmpty) {
              changed = true;
              continue;
            }
            // Kayıtlı dosya hâlâ var mı? Yoksa girişi atla (prune).
            if (!File(path).existsSync()) {
              changed = true;
              continue;
            }
            _saved[track.id] = path;
            _savedTracks[track.id] = track;
          }
        }
      }

      final rawGroups = prefs.getString(_groupsKey);
      if (rawGroups != null && rawGroups.isNotEmpty) {
        final decoded = jsonDecode(rawGroups);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.value is! Map) continue;
            final group = DownloadGroup.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            );
            final id = group.id.isNotEmpty ? group.id : entry.key.toString();
            if (id.isEmpty) continue;
            _groups[id] = DownloadGroup(
              id: id,
              name: group.name,
              trackIds: group.trackIds,
              createdAt: group.createdAt,
            );
          }
        }
      }
    } catch (_) {
      // Bozuk kayıt varsa sessizce yok sayılır.
    }

    // Hafızadaki (önceki yüklemelerden kalmış) girdileri de doğrula.
    final invalid = _saved.entries
        .where((entry) => !File(entry.value).existsSync())
        .map((entry) => entry.key)
        .toList();
    for (final id in invalid) {
      _saved.remove(id);
      _savedTracks.remove(id);
      changed = true;
    }

    if (changed) await _persistState();
    notifyListeners();
  }

  Future<void> _persistState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = _saved.entries.map((entry) {
        return {
          'track': _savedTracks[entry.key]?.toJson(),
          'path': entry.value,
        };
      }).toList();
      await prefs.setString(_storageKey, jsonEncode(data));
    } catch (_) {}
  }

  Future<void> _persistGroups() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = _groups.map(
        (key, value) => MapEntry<String, dynamic>(key, value.toJson()),
      );
      await prefs.setString(_groupsKey, jsonEncode(data));
    } catch (_) {}
  }

  Future<String?> download(Track track, {int maxAttempts = 3}) async {
    await init();
    final existing = savedPathOf(track.id);
    if (existing != null && File(existing).existsSync()) return existing;
    if (_progress.containsKey(track.id)) return null;

    _cancelled.remove(track.id);
    _cancelSignals.remove(track.id)?.complete();
    _cancelledByUser.remove(track.id);
    _failures.remove(track.id);
    _failureReason.remove(track.id);
    _failedTracks.remove(track.id);
    _progress[track.id] = 0;
    notifyListeners();

    try {
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        if (_cancelled.remove(track.id)) break;
        final result = await _downloadOnce(track);
        if (result != null) return result;
        if (_cancelled.remove(track.id)) break;
        if (attempt < maxAttempts) {
          try {
            YoutubeService.instance.dropUri(track.id);
          } catch (_) {}
          _progress[track.id] = 0;
          notifyListeners();
          await Future<void>.delayed(Duration(milliseconds: 600 * attempt));
        }
      }
    } finally {
      _cancelled.remove(track.id);
      _cancelSignals.remove(track.id);
      _progress.remove(track.id);
      notifyListeners();
    }
    return null;
  }

  Future<String?> _downloadOnce(Track track) async {
    File? temp;
    http.Client? client;
    IOSink? sink;
    _cancelSignals.putIfAbsent(track.id, () => Completer<void>());
    try {
      if (_cancelled.contains(track.id)) throw StateError('download-cancelled');
      Uri uri;
      final source = track.sourceUrl;
      if (source != null && source.trim().isNotEmpty) {
        uri = Uri.parse(source);
      } else {
        uri = await _raceCancel(track.id, _resolveDownloadUri(track));
      }

      if (_cancelled.contains(track.id)) throw StateError('download-cancelled');
      final host = uri.host;
      final isGoogle = host.contains('googlevideo') || host.contains('youtube');
      final request = http.Request('GET', uri)
        ..headers['User-Agent'] =
            'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36'
        ..headers['Accept-Encoding'] = 'identity';
      if (isGoogle) {
        request.headers['Referer'] = 'https://www.youtube.com/';
        request.headers['Origin'] = 'https://www.youtube.com';
      }

      final directory = await getTemporaryDirectory();

      client = http.Client();
      _activeClients[track.id] = client;
      final response = await _raceCancel(
        track.id,
        client.send(request).timeout(const Duration(seconds: 35)),
      );
      if (response.statusCode != 200) {
        throw StateError('download-http-${response.statusCode}');
      }

      final extension = _extensionFor(response.headers['content-type'], uri);
      temp = File('${directory.path}/ct_${track.id}$extension');

      final total = response.contentLength ?? 0;
      sink = temp.openWrite();
      var received = 0;
      var lastProgressAt = DateTime.now();
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 60),
      )) {
        if (_cancelled.contains(track.id)) {
          throw StateError('download-cancelled');
        }
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (total > 0 &&
            (now.difference(lastProgressAt).inMilliseconds > 250 ||
                received == total)) {
          lastProgressAt = now;
          _progress[track.id] = (received / total).clamp(0.0, 1.0);
          notifyListeners();
        }
      }
      await sink.close();
      sink = null;

      if (received <= 0) throw StateError('download-empty');

      final path = await _persist(track, temp, extension);
      if (path == null) throw StateError('download-persist-failed');

      _saved[track.id] = path;
      _savedTracks[track.id] = track;
      _failures.remove(track.id);
      _failureReason.remove(track.id);
      _failedTracks.remove(track.id);
      await _persistState();
      unawaited(Library.instance.remember(track));
      _progress.remove(track.id);
      notifyListeners();
      return path;
    } catch (error) {
      if (_cancelled.contains(track.id) ||
          error.toString().contains('download-cancelled')) {
        _failures.remove(track.id);
        _failureReason.remove(track.id);
        _failedTracks.remove(track.id);
      } else {
        _failures.add(track.id);
        _failureReason[track.id] = error.toString();
        _failedTracks[track.id] = track;
      }
      notifyListeners();
      return null;
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      _activeClients.remove(track.id);
      client?.close();
      try {
        if (temp != null && await temp.exists()) await temp.delete();
      } catch (_) {}
    }
  }

  Future<Uri> _resolveDownloadUri(Track track) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final uri = await YoutubeService.instance
            .audioUri(track.id)
            .timeout(const Duration(seconds: 35));
        return uri;
      } catch (e) {
        lastError = e;
      }
      try {
        YoutubeService.instance.dropUri(track.id);
      } catch (_) {}
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    throw StateError('download-uri-unavailable: ${lastError ?? 'unknown'}');
  }

  /// Toplu indirme. Paralellik [_maxParallel] ile sınırlıdır; tek bir hata
  /// kalan parçaları durdurmaz. Dönen liste girdiyle aynı sıradadır ve her
  /// parça için kaydedilen yolu, başarısızlıkta boş dizgeyi içerir
  /// (nedenler `failureIds` / `failureReasons` üzerinden de okunabilir).
  Future<List<String>> downloadAll(
    List<Track> tracks, {
    void Function(int done, int total)? onProgress,
  }) async {
    await init();
    final total = tracks.length;
    final results = List<String>.filled(total, '');
    onProgress?.call(0, total);
    if (total == 0) return results;

    // Aynı id'yi bir kez indir; sonuçları tüm indekslere yay.
    final uniqueIndices = <int>[];
    final seenIds = <String>{};
    for (var i = 0; i < total; i++) {
      final id = tracks[i].id;
      if (seenIds.add(id)) uniqueIndices.add(i);
    }

    Future<void> runPass(List<int> indices, {required bool countProgress}) async {
      var next = 0;
      var done = 0;
      final workerCount = _maxParallel < indices.length ? _maxParallel : indices.length;
      final workers = List<Future<void>>.generate(workerCount, (_) async {
        while (true) {
          final cursor = next++;
          if (cursor >= indices.length) return;
          final index = indices[cursor];
          final path = await download(tracks[index]);
          results[index] = path ?? '';
          if (countProgress) {
            done++;
            onProgress?.call(done, uniqueIndices.length);
          }
        }
      });
      await Future.wait(workers);
    }

    await runPass(uniqueIndices, countProgress: true);

    final retryIndices = <int>[];
    for (final i in uniqueIndices) {
      final id = tracks[i].id;
      if (results[i].isEmpty &&
          savedPathOf(id) == null &&
          !_cancelledByUser.contains(id)) {
        retryIndices.add(i);
      }
    }
    _cancelledByUser.removeWhere((id) => tracks.any((t) => t.id == id));
    if (retryIndices.isNotEmpty) {
      await Future<void>.delayed(const Duration(seconds: 2));
      await runPass(retryIndices, countProgress: false);
    }

    // Dedupe sonuçlarını tüm eşleşen indekslere yay.
    final byId = <String, String>{};
    for (final i in uniqueIndices) {
      final p = results[i].isNotEmpty ? results[i] : (savedPathOf(tracks[i].id) ?? '');
      byId[tracks[i].id] = p;
    }
    for (var i = 0; i < total; i++) {
      results[i] = byId[tracks[i].id] ?? results[i];
    }
    onProgress?.call(total, total);
    return results;
  }

  /// Sanatçının parçalarını indirir ve kalıcı bir grup olarak kaydeder.
  Future<void> saveArtistPlaylist(
    String artistId,
    String artistName,
    List<Track> tracks,
  ) async {
    await init();
    await downloadAll(tracks);
    final key = artistId.trim().isEmpty ? artistName.trim() : artistId.trim();
    final id = 'artist:$key';
    _groups[id] = DownloadGroup(
      id: id,
      name: artistName.trim().isEmpty ? 'Sanatçı' : artistName.trim(),
      trackIds: _downloadedIds(tracks),
      createdAt: _groups[id]?.createdAt ?? DateTime.now(),
    );
    await _persistGroups();
    notifyListeners();
  }

  /// Arama sonuçlarını indirir ve kalıcı bir grup olarak kaydeder.
  Future<void> saveSearchPlaylist(String name, List<Track> tracks) async {
    await init();
    await downloadAll(tracks);
    final id = 'search:${name.trim()}';
    _groups[id] = DownloadGroup(
      id: id,
      name: name.trim().isEmpty ? 'Arama' : name.trim(),
      trackIds: _downloadedIds(tracks),
      createdAt: _groups[id]?.createdAt ?? DateTime.now(),
    );
    await _persistGroups();
    notifyListeners();
  }

  List<String> _downloadedIds(List<Track> tracks) {
    final ids = <String>[];
    final seen = <String>{};
    for (final track in tracks) {
      if (savedPathOf(track.id) == null) continue;
      if (seen.add(track.id)) ids.add(track.id);
    }
    return ids;
  }

  /// Başarısız bir indirmeyi, bilinen parça bilgisiyle yeniden dener.
  Future<void> retryDownload(String id) async {
    final track =
        failedTrack(id) ?? Track(id: id, title: id, artist: 'Bilinmeyen');
    await download(track);
  }

  /// İndirmeyi (dosya + tüm ilişkili durum) kaldırır.
  Future<bool> deleteDownload(String id) async {
    await init();
    await _deleteTrackEntry(id);
    final groupsChanged = _pruneTrackFromGroups(id, removeEmpty: true);
    if (groupsChanged) await _persistGroups();
    await _persistState();
    notifyListeners();
    return true;
  }

  /// Bir indirme grubunu ve grubun sahip olduğu parçaları siler.
  /// Parça başka bir grupta da varsa dosya korunur, yalnızca bu grubun kaydı
  /// kaldırılır.
  Future<bool> deleteGroup(String groupId) async {
    await init();
    final key = _groups.containsKey(groupId)
        ? groupId
        : _groups.entries
            .where((e) => e.value.id == groupId || e.value.name == groupId)
            .map((e) => e.key)
            .cast<String?>()
            .firstWhere((_) => true, orElse: () => null);
    if (key == null) return false;
    final group = _groups.remove(key);
    if (group == null) return false;

    final retained = <String>{};
    for (final entry in _groups.values) {
      retained.addAll(entry.trackIds);
    }

    var changedFiles = false;
    for (final id in group.trackIds) {
      if (retained.contains(id)) continue;
      final had = _saved.containsKey(id) ||
          _savedTracks.containsKey(id) ||
          _failures.contains(id) ||
          _failedTracks.containsKey(id) ||
          _failureReason.containsKey(id);
      await _deleteTrackEntry(id);
      if (had) changedFiles = true;
    }

    _pruneMissingGroupTracks();

    try {
      await _persistGroups();
      if (changedFiles) await _persistState();
    } catch (_) {}
    notifyListeners();
    return !_groups.containsKey(key);
  }

  /// Eski uyumluluk adı.
  Future<bool> removeGroup(String groupId) => deleteGroup(groupId);

  Future<void> _deleteTrackEntry(String id) async {
    final path = _saved.remove(id);
    _savedTracks.remove(id);
    _failures.remove(id);
    _failureReason.remove(id);
    _failedTracks.remove(id);

    _activeClients[id]?.close();
    _activeClients.remove(id);
    _cancelled.remove(id);
    _cancelSignals.remove(id)?.complete();
    _progress.remove(id);

    if (path != null) {
      try {
        final file = File(path);
        if (file.existsSync()) await file.delete();
      } catch (_) {}
    }
  }

  bool _pruneTrackFromGroups(String id, {required bool removeEmpty}) {
    var groupsChanged = false;
    final emptyIds = <String>[];
    for (final entry in _groups.entries) {
      if (!entry.value.trackIds.contains(id)) continue;
      final nextIds =
          entry.value.trackIds.where((item) => item != id).toList();
      if (removeEmpty && nextIds.isEmpty) {
        emptyIds.add(entry.key);
      } else {
        _groups[entry.key] = DownloadGroup(
          id: entry.value.id,
          name: entry.value.name,
          trackIds: nextIds,
          createdAt: entry.value.createdAt,
        );
      }
      groupsChanged = true;
    }
    for (final emptyId in emptyIds) {
      _groups.remove(emptyId);
    }
    return groupsChanged;
  }

  void _pruneMissingGroupTracks() {
    final emptyIds = <String>[];
    for (final entry in _groups.entries.toList()) {
      final nextIds = entry.value.trackIds
          .where((id) =>
              _saved.containsKey(id) ||
              _savedTracks.containsKey(id) ||
              _progress.containsKey(id) ||
              _failures.contains(id))
          .toList();
      if (nextIds.length == entry.value.trackIds.length) continue;
      if (nextIds.isEmpty) {
        emptyIds.add(entry.key);
      } else {
        _groups[entry.key] = DownloadGroup(
          id: entry.value.id,
          name: entry.value.name,
          trackIds: nextIds,
          createdAt: entry.value.createdAt,
        );
      }
    }
    for (final emptyId in emptyIds) {
      _groups.remove(emptyId);
    }
  }

  String _safeName(Track track) {
    final base = '$track.artist - $track.title'
        .replaceAll(RegExp(r'[^\p{L}\p{N} _.-]', unicode: true), '')
        .trim();
    final name = base.isEmpty ? 'CloudTune ${track.id}' : base;
    return name.length > 90 ? name.substring(0, 90) : name;
  }

  /// İçerik türü → dosya uzantısı. Bilinmeyen/octet-stream durumunda `null`
  /// döner; böylece itag ve URL bilgisi devreye girebilir.
  static String? _extensionFromMime(String? value) {
    if (value == null || value.isEmpty) return null;
    final mime = value.toLowerCase();
    if (mime.contains('webm') ||
        mime.contains('opus') ||
        mime.contains('ogg')) {
      return '.webm';
    }
    if (mime.contains('mpeg') || mime.contains('mp3')) return '.mp3';
    if (mime.contains('mp4') || mime.contains('m4a') || mime.contains('aac')) {
      return '.m4a';
    }
    return null;
  }

  static String? _extensionFromItag(int? itag) {
    if (itag == null) return null;
    switch (itag) {
      case 171:
      case 249:
      case 250:
      case 251:
        return '.webm';
      case 139:
      case 140:
      case 141:
      case 600:
        return '.m4a';
      default:
        return null;
    }
  }

  static String? _extensionFromPath(String path) {
    final lower = path.toLowerCase();
    for (final ext in const <String>['.webm', '.m4a', '.mp3', '.mp4', '.ogg', '.opus']) {
      if (!lower.endsWith(ext)) continue;
      if (ext == '.mp4') return '.m4a';
      if (ext == '.ogg' || ext == '.opus') return '.webm';
      return ext;
    }
    return null;
  }

  static String _extensionFor(String? contentType, Uri uri) {
    final fromHeader = _extensionFromMime(contentType);
    if (fromHeader != null) return fromHeader;

    final fromUriMime = _extensionFromMime(uri.queryParameters['mime']);
    if (fromUriMime != null) return fromUriMime;

    final fromItag = _extensionFromItag(
      int.tryParse(uri.queryParameters['itag'] ?? ''),
    );
    if (fromItag != null) return fromItag;

    return _extensionFromPath(uri.path) ?? '.m4a';
  }

  static String _mimeFor(String extension) => switch (extension) {
        '.webm' => 'audio/webm',
        '.mp3' => 'audio/mpeg',
        _ => 'audio/mp4',
      };

  /// Oynatma kopyasını her zaman uygulama belgelerine yazar ve mutlak yol
  /// döndürür. Android + ayar açıksa MediaStore'a ek kopya için çağrı yapılır;
  /// dönen göreli yol asla kullanılmaz. İzin yoksa uygulama klasöründeki kopya
  /// kalır, istisna dışarı sızmaz.
  Future<String?> _persist(Track track, File file, String extension) async {
    final directory = await getApplicationDocumentsDirectory();
    _libraryDir = directory.path;
    final out = Directory('${directory.path}/CloudTune');
    if (!await out.exists()) await out.create(recursive: true);
    final fileName = '${_safeName(track)}-${track.id}$extension';
    final target = File('${out.path}/$fileName');
    await file.copy(target.path);

    if (Library.instance.downloadToDevice && Platform.isAndroid) {
      try {
        await _saver.invokeMethod<String>('saveAudioToLibrary', {
          'path': target.path,
          'title': track.title,
          'artist': track.artist,
          'mime': _mimeFor(extension),
          'extension': extension,
          'displayName': fileName,
        });
      } catch (_) {
        // MediaStore başarısızsa (izin yoksa da) uygulama kopyası kalır.
      }
    }

    return target.path;
  }
}
