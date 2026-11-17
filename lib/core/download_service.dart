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

/// Parçaları cihaza kaydeder. Oynatma kopyası HER ZAMAN uygulama
/// belgelerinde tutulur; Android'de isteğe bağlı MediaStore kopyası yalnızca
/// galeri görünürlüğü içindir ve asla oynatma yolu olarak kullanılmaz.
class DownloadService extends ChangeNotifier {
  DownloadService._();

  static final DownloadService instance = DownloadService._();

  static const MethodChannel _saver = MethodChannel('cloudtune/saver');
  static const String _storageKey = 'ct.downloads';

  final Map<String, double> _progress = <String, double>{};
  final Map<String, String> _saved = <String, String>{};
  final Map<String, Track> _savedTracks = <String, Track>{};
  final Set<String> _failures = <String>{};
  final Map<String, String> _failureReason = <String, String>{};
  final Map<String, Track> _failedTracks = <String, Track>{};

  Future<void>? _initFuture;

  Future<void> init() => _initFuture ??= _load();

  bool isDownloading(String id) => _progress.containsKey(id);

  double progressOf(String id) => _progress[id] ?? 0;

  String? savedPathOf(String id) => _saved[id];

  int get activeCount => _progress.length;

  /// Negatif değer onarım botu için hata işaretidir.
  Map<String, double> get downloadProgress => {
        ..._progress,
        for (final id in _failures) id: -1,
      };

  List<Track> get savedTracks =>
      List<Track>.unmodifiable(_savedTracks.values);

  Set<String> get failureIds => Set.unmodifiable(_failures);

  String? failureReason(String id) => _failureReason[id];

  Track? failedTrack(String id) => _failedTracks[id];

  void forgetFailure(String id) {
    _failures.remove(id);
    _failureReason.remove(id);
    _failedTracks.remove(id);
    notifyListeners();
  }

  Future<void> _load() async {
    var changed = false;
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

  Future<String?> download(Track track) async {
    final existing = savedPathOf(track.id);
    if (existing != null && File(existing).existsSync()) return existing;
    if (_progress.containsKey(track.id)) return null;

    _failures.remove(track.id);
    _failureReason.remove(track.id);
    _failedTracks.remove(track.id);
    _progress[track.id] = 0;
    notifyListeners();

    File? temp;
    http.Client? client;
    try {
      Uri uri;
      final source = track.sourceUrl;
      if (source != null && source.trim().isNotEmpty) {
        uri = Uri.parse(source);
      } else {
        try {
          uri = await YoutubeService.instance.audioUri(track.id);
        } catch (_) {
          final forced = await YoutubeService.instance.forceDirect(track.id);
          if (forced == null) throw StateError('download-uri-unavailable');
          uri = forced;
        }
      }

      final host = uri.host;
      final isGoogle =
          host.contains('googlevideo') || host.contains('youtube');
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
      temp = File('${directory.path}/ct_${track.id}.m4a');

      client = http.Client();
      final response = await client.send(request).timeout(
            const Duration(seconds: 30),
          );
      if (response.statusCode != 200) {
        throw StateError('download-http-${response.statusCode}');
      }

      final total = response.contentLength ?? 0;
      final sink = temp.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          _progress[track.id] = (received / total).clamp(0.0, 1.0);
          notifyListeners();
        }
      }
      await sink.close();

      if (received <= 0) throw StateError('download-empty');

      final path = await _persist(track, temp);
      if (path == null) throw StateError('download-persist-failed');

      _saved[track.id] = path;
      _savedTracks[track.id] = track;
      _failures.remove(track.id);
      _failureReason.remove(track.id);
      _failedTracks.remove(track.id);
      await _persistState();
      unawaited(Library.instance.remember(track));
      return path;
    } catch (error) {
      _failures.add(track.id);
      _failureReason[track.id] = error.toString();
      _failedTracks[track.id] = track;
      notifyListeners();
      return null;
    } finally {
      client?.close();
      _progress.remove(track.id);
      notifyListeners();
      try {
        if (temp != null && await temp.exists()) await temp.delete();
      } catch (_) {}
    }
  }

  /// Başarısız bir indirmeyi, bilinen parça bilgisiyle yeniden dener.
  Future<void> retryDownload(String id) async {
    final track = failedTrack(id) ??
        Track(id: id, title: id, artist: 'Bilinmeyen');
    await download(track);
  }

  /// İndirmeyi (dosya + tüm ilişkili durum) kaldırır.
  Future<bool> deleteDownload(String id) async {
    final path = _saved.remove(id);
    _savedTracks.remove(id);
    _failures.remove(id);
    _failureReason.remove(id);
    _failedTracks.remove(id);

    if (path != null) {
      try {
        final file = File(path);
        if (file.existsSync()) await file.delete();
      } catch (_) {}
    }

    await _persistState();
    notifyListeners();
    return true;
  }

  String _safeName(Track track) {
    final base = '$track.artist - $track.title'
        .replaceAll(RegExp(r'[^\p{L}\p{N} _.-]', unicode: true), '')
        .trim();
    final name = base.isEmpty ? 'CloudTune ${track.id}' : base;
    return name.length > 90 ? name.substring(0, 90) : name;
  }

  /// Oynatma kopyasını her zaman uygulama belgelerine yazar ve mutlak yol
  /// döndürür. Android + ayar açıksa MediaStore'a ek kopya için çağrı yapılır;
  /// dönen göreli yol asla kullanılmaz.
  Future<String?> _persist(Track track, File file) async {
    final directory = await getApplicationDocumentsDirectory();
    final out = Directory('${directory.path}/CloudTune');
    if (!await out.exists()) await out.create(recursive: true);
    final target = File('${out.path}/${_safeName(track)}-${track.id}.m4a');
    await file.copy(target.path);

    if (Library.instance.downloadToDevice && Platform.isAndroid) {
      try {
        await _saver.invokeMethod<String>('saveAudioToLibrary', {
          'path': target.path,
          'title': track.title,
          'artist': track.artist,
        });
      } catch (_) {
        // MediaStore başarısızsa uygulama klasöründeki kopya kalır.
      }
    }

    return target.path;
  }
}
