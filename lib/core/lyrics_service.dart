import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Yerel `.lrc` dosyalarından senkronize şarkı sözü okur.
/// Dosyalar `Belgeler/CloudTune/Lyrics/<videoId>.lrc` yolunda aranır.
class LyricLine {
  const LyricLine(this.time, this.text);

  final Duration time;
  final String text;
}

class LyricsService {
  LyricsService._();

  static final LyricsService instance = LyricsService._();

  final Map<String, List<LyricLine>> _cache = {};

  Future<Directory> _lyricsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/CloudTune/Lyrics');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> directoryPath() async => (await _lyricsDir()).path;

  Future<void> clearCache() async => _cache.clear();

  Future<List<LyricLine>> load(String videoId) async {
    if (videoId.isEmpty) return const <LyricLine>[];
    final cached = _cache[videoId];
    if (cached != null) return cached;
    try {
      final dir = await _lyricsDir();
      final file = File('${dir.path}/$videoId.lrc');
      if (!await file.exists()) return const <LyricLine>[];
      final lines = _parse(await file.readAsString());
      _cache[videoId] = lines;
      return lines;
    } catch (_) {
      return const <LyricLine>[];
    }
  }

  static List<LyricLine> _parse(String raw) {
    final result = <LyricLine>[];
    final stamp = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      final matches = stamp.allMatches(line).toList();
      if (matches.isEmpty) continue;
      final text = line.substring(matches.last.end).trim();
      if (text.isEmpty) continue;
      for (final match in matches) {
        final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
        final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
        final fraction = match.group(3) ?? '';
        final millis = fraction.isEmpty
            ? 0
            : (int.tryParse(fraction) ?? 0) *
                (fraction.length == 2 ? 10 : (fraction.length == 1 ? 100 : 1));
        result.add(
          LyricLine(
            Duration(minutes: minutes, seconds: seconds, milliseconds: millis),
            text,
          ),
        );
      }
    }
    result.sort((a, b) => a.time.compareTo(b.time));
    return List.unmodifiable(result);
  }

  static int activeIndex(List<LyricLine> lines, Duration position) {
    var low = 0;
    var high = lines.length - 1;
    var answer = -1;
    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      if (lines[mid].time <= position) {
        answer = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return answer;
  }
}
