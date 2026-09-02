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
  final Set<String> _active = {};

  /// songId -> 0.0..1.0
  Map<String, double> get progress => Map.unmodifiable(_progress);
  bool isDownloading(String id) => _active.contains(id);

  Directory? _dir;

  Future<void> _init() async {
    final docs = await getApplicationDocumentsDirectory();
    _dir = Directory('${docs.path}/$downloadsFolderName');
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
    // Kayıtlı ama dosyası silinmiş indirmeleri temizle.
    for (final song in library.downloads) {
      if (song.localPath == null || !await File(song.localPath!).exists()) {
        library.removeDownload(song.id);
      }
    }
  }

  String audioPath(String id) => '${_dir!.path}/$id.m4a';
  String artPath(String id) => '${_dir!.path}/$id.jpg';

  Future<void> download(Song song) async {
    if (_active.contains(song.id) || library.isDownloaded(song.id)) return;
    _active.add(song.id);
    _progress[song.id] = 0.0;
    notifyListeners();

    try {
      if (_dir == null) await _init();
      final streamUrl = await music.resolveStreamUrl(song.id);

      // Ses dosyası: akışı parça parça yaz, ilerleme yay.
      await _downloadFile(streamUrl, audioPath(song.id), (received, total) {
        if (total > 0) {
          // İlerlemenin %0..92'si ses dosyasına karşılık gelir.
          _progress[song.id] = (received / total) * 0.92;
          notifyListeners();
        }
      });

      // Kapak görseli.
      try {
        if (song.thumbnailUrl.isNotEmpty) {
          final bytes = await _fetchBytes(song.thumbnailUrl);
          await File(artPath(song.id)).writeAsBytes(bytes, flush: true);
        }
      } catch (_) {}

      library.addDownload(song.copyWith(localPath: audioPath(song.id)));
      _progress[song.id] = 1.0;
    } catch (e) {
      debugPrint('İndirme hatası (${song.title}): $e');
      try {
        final f = File(audioPath(song.id));
        if (await f.exists()) await f.delete();
      } catch (_) {}
      rethrow;
    } finally {
      _active.remove(song.id);
      notifyListeners();
      Future.delayed(const Duration(seconds: 2), () {
        if (_progress[song.id] != null && !_active.contains(song.id)) {
          _progress.remove(song.id);
          notifyListeners();
        }
      });
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
  }

  Future<void> clearAll() async {
    for (final song in library.downloads) {
      await delete(song);
    }
  }

  Future<void> _downloadFile(
    String url,
    String savePath,
    void Function(int received, int total) onProgress,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final total =
          response.contentLength > 0 ? response.contentLength : 0;
      var received = 0;
      final sink = File(savePath).openWrite();
      try {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          onProgress(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
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
