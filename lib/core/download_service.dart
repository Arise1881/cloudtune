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

/// Parçaları cihaza kaydeder. Android'de MediaStore, diğer platformlarda
/// uygulama belgeleri kullanılır. Kayıtlı parçalar uygulama açılışında geri yüklenir.
class DownloadService extends ChangeNotifier {
  DownloadService._();

  static final DownloadService instance = DownloadService._();

  static const MethodChannel _saver = MethodChannel('cloudtune/saver');
  static const String _storageKey = 'ct.downloads';

  final Map<String, double> _progress = <String, double>{};
  final Map<String, String> _saved = <String, String>{};
  final Map<String, Track> _savedTracks = <String, Track>{};
  final Set<String> _failures = <String>{};

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

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final data = jsonDecode(raw);
        if (data is List) {
          for (final item in data) {
            if (item is! Map<String, dynamic>) continue;
            final track = Track.fromJson(
              Map<String, dynamic>.from(item['track'] as Map? ?? const {}),
            );
            final path = item['path']?.toString();
            if (track.id.isEmpty || path == null || path.isEmpty) continue;
            _saved[track.id] = path;
            _savedTracks[track.id] = track;
          }
        }
      }
    } catch (_) {
      // Bozuk kayıt varsa sessizce yok sayılır.
    }
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
    if (existing != null) return existing;
    if (_progress.containsKey(track.id)) return null;

    _failures.remove(track.id);
    _progress[track.id] = 0;
    notifyListeners();

    File? temp;
    try {
      final uri = await YoutubeService.instance.audioUri(track.id);
      final directory = await getTemporaryDirectory();
      temp = File('${directory.path}/ct_${track.id}.m4a');

      final request = http.Request('GET', uri)
        ..headers['User-Agent'] =
            'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36';
      final response = await http.Client().send(request);
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

      final path = await _persist(track, temp);
      if (path == null) throw StateError('download-persist-failed');

      _saved[track.id] = path;
      _savedTracks[track.id] = track;
      await _persistState();
      unawaited(Library.instance.remember(track));
      return path;
    } catch (_) {
      _failures.add(track.id);
      return null;
    } finally {
      _progress.remove(track.id);
      notifyListeners();
      try {
        if (temp != null && await temp.exists()) await temp.delete();
      } catch (_) {}
    }
  }

  String _safeName(Track track) {
    final base = '$track.artist - $track.title'
        .replaceAll(RegExp(r'[^\p{L}\p{N} _.-]', unicode: true), '')
        .trim();
    final name = base.isEmpty ? 'CloudTune ${track.id}' : base;
    return name.length > 90 ? name.substring(0, 90) : name;
  }

  Future<String?> _persist(Track track, File file) async {
    if (Library.instance.downloadToDevice && Platform.isAndroid) {
      try {
        final path = await _saver.invokeMethod<String>('saveAudioToLibrary', {
          'path': file.path,
          'title': track.title,
          'artist': track.artist,
        });
        if (path != null && path.isNotEmpty) return path;
      } catch (_) {
        // MediaStore başarısızsa uygulama klasörüne düş.
      }
    }

    final directory = await getApplicationDocumentsDirectory();
    final out = Directory('${directory.path}/CloudTune');
    if (!await out.exists()) await out.create(recursive: true);
    final target = File('${out.path}/${_safeName(track)}.m4a');
    await file.copy(target.path);
    return target.path;
  }
}
