import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'library.dart';
import 'models.dart';
import 'youtube_service.dart';

/// Sarkilari cihaza indirir. Android'de MediaStore uzerinden
/// Download/CloudTune klasorune yazar; masaustunde Indirilenler'e kopyalar.
class DownloadService extends ChangeNotifier {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  static const MethodChannel _saver = MethodChannel('cloudtune/saver');

  final Map<String, double> _progress = {};
  final Map<String, String> _saved = {};

  bool isDownloading(String id) => _progress.containsKey(id);
  double progressOf(String id) => _progress[id] ?? 0;
  String? savedPathOf(String id) => _saved[id];
  int get activeCount => _progress.length;

  Future<String?> download(Track track) async {
    if (_progress.containsKey(track.id)) return _saved[track.id];
    _progress[track.id] = 0;
    notifyListeners();
    File? temp;
    try {
      final uri = await YoutubeService.instance.audioUri(track.id);
      final dir = await getTemporaryDirectory();
      temp = File('${dir.path}/ct_${track.id}.m4a');
      final request = http.Request('GET', uri);
      final response = await http.Client().send(request);
      if (response.statusCode != 200) return null;
      final total = response.contentLength ?? 0;
      final sink = temp.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          _progress[track.id] = received / total;
          notifyListeners();
        }
      }
      await sink.close();
      final saved = await _persist(track, temp);
      if (saved != null) _saved[track.id] = saved;
      return saved;
    } catch (_) {
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
    final base = '${track.artist} - ${track.title}'
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
        if (path != null) return path;
      } catch (_) {
        // MediaStore basarisizsa uygulama klasorune dus.
      }
    }
    final dir = await getApplicationDocumentsDirectory();
    final out = Directory('${dir.path}/CloudTune');
    if (!await out.exists()) await out.create(recursive: true);
    final target = File('${out.path}/${_safeName(track)}.m4a');
    await file.copy(target.path);
    return target.path;
  }
}
