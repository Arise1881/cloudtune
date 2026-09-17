import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../constants.dart';
import '../models/song.dart';
import 'library_store.dart';
import 'music_service.dart';

/// Şarkıları yerel depolamaya indirir; indirme ilerlemesini yayınlar.
class DownloadManager extends ChangeNotifier {
  DownloadManager._() {
    _init();
  }

  static final DownloadManager instance = DownloadManager._();

  final LibraryStore library = LibraryStore.instance;
  final MusicService music = MusicService.instance;

  final Map<String, double> _progress = {};
  final Map<String, bool> _completed = {};
  final Set<String> _active = {};

  Map<String, double> get progress => Map.unmodifiable(_progress);
  Map<String, bool> get completed => Map.unmodifiable(_completed);
  bool isDownloading(String id) => _active.contains(id);
  bool isCompleted(String id) => _completed[id] ?? false;

  Directory? _dir;

  Future<void> _init() async {
    final docs = await getApplicationDocumentsDirectory();
    _dir = Directory('${docs.path}/$downloadsFolderName');
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
    for (final song in library.downloads) {
      if (song.localPath == null || !await File(song.localPath!).exists()) {
        library.removeDownload(song.id);
        _completed.remove(song.id);
      }
    }
  }

  String audioPath(String id) => '${_dir!.path}/$id.m4a';
  String artPath(String id) => '${_dir!.path}/$id.jpg';

  Future<String?> download(Song song) async {
    if (_active.contains(song.id) || library.isDownloaded(song.id)) {
      return null;
    }
    _active.add(song.id);
    _progress[song.id] = 0.0;
    _completed.remove(song.id);
    notifyListeners();

    try {
      if (_dir == null) await _init();

      final candidates = await music.streamUrlCandidates(song.id);
      if (candidates.isEmpty) {
        throw StreamUnavailableException('Akış çözülemedi');
      }

      final approxTotal = song.durationMs > 0
          ? song.durationMs * 16
          : 0;

      String? lastErrorText;
      var ok = false;
      for (final url in candidates) {
        try {
          await _downloadFile(url, audioPath(song.id), approxTotal, onProgress: (received, total) {
            double p;
            if (total > 0) {
              p = (received / total).clamp(0.0, 1.0);
            } else {
              p = (received / (approxTotal > 0 ? approxTotal : 1)).clamp(0.0, 1.0);
            }
            _progress[song.id] = p;
            notifyListeners();
          });
          ok = true;
          break;
        } catch (e) {
          lastErrorText = e.toString();
          try {
            final f = File(audioPath(song.id));
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }
      if (!ok) throw Exception(lastErrorText ?? 'İndirme başarısız');

      try {
        if (song.thumbnailUrl.isNotEmpty) {
          final bytes = await _fetchBytes(song.thumbnailUrl);
          await File(artPath(song.id)).writeAsBytes(bytes, flush: true);
        }
      } catch (_) {}

      library.addDownload(song.copyWith(localPath: audioPath(song.id)));
      await _saveToDevice(song);

      _progress[song.id] = 1.0;
      _completed[song.id] = true;
      notifyListeners();
      return null;
    } catch (e) {
      debugPrint('İndirme hatası (${song.title}): $e');
      try {
        final f = File(audioPath(song.id));
        if (await f.exists()) await f.delete();
      } catch (_) {}
      final msg = e.toString().replaceFirst('Exception: ', '');
      _progress.remove(song.id);
      _completed.remove(song.id);
      notifyListeners();
      return msg.isEmpty ? 'İndirme başarısız' : msg;
    } finally {
      _active.remove(song.id);
      notifyListeners();
    }
  }

  Future<void> delete(Song song) async {
    for (final path in [song.localPath, artPath(song.id)]) {
      if (path == null) continue;
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    library.removeDownload(song.id);
    _progress.remove(song.id);
    _completed.remove(song.id);
    notifyListeners();
  }

  Future<void> clearAll() async {
    for (final song in library.downloads) {
      await delete(song);
    }
  }

  Future<int> totalSizeBytes() async {
    final dir = _dir;
    if (dir == null || !await dir.exists()) return 0;
    var total = 0;
    try {
      await for (final e in dir.list(followLinks: false)) {
        if (e is File) {
          total += await e.length();
        }
      }
    } catch (_) {}
    return total;
  }

  String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _downloadFile(
    String url,
    String savePath,
    int approxTotal, {
    required void Function(int received, int total) onProgress,
  }) async {
    int attempt = 0;
    while (true) {
      attempt++;
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 30);
      try {
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set(HttpHeaders.userAgentHeader,
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36');
        final response = await request.close().timeout(const Duration(seconds: 30));
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('HTTP ${response.statusCode}');
        }
        var total = response.contentLength > 0 ? response.contentLength : approxTotal;
        var received = 0;
        final sink = File(savePath).openWrite();
        try {
          await for (final chunk in response.timeout(const Duration(seconds: 30))) {
            received += chunk.length;
            sink.add(chunk);
            onProgress(received, total);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        break;
      } catch (e) {
        client.close(force: true);
        if (attempt >= 3) rethrow;
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
  }

  Future<void> _saveToDevice(Song song) async {
    final audioFile = File(audioPath(song.id));
    if (!await audioFile.exists()) {
      throw Exception('Ses dosyası bulunamadı');
    }

    if (!kIsWeb && Platform.isAndroid) {
      try {
        final uri = 'file://${audioPath(song.id)}';
        debugPrint('MediaStore scan: $uri');
      } catch (_) {}
    }
  }

  Future<Uint8List> _fetchBytes(String url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }
}
