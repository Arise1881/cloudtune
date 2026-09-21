import 'package:flutter/material.dart';

/// LRC (LyRiCs) formatı çözümleyici — zaman damgalı sözler için.
/// Desteklenen formatlar:
/// [mm:ss.xx]Söz satırı
/// [mm:ss]Söz satırı
/// [mm:ss.xxx]Söz satırı
/// [mm:ss.xx][mm:ss.xx]Çoklu zaman damgası
class LrcParser {
  const LrcParser();

  /// LRC metnini parse eder, [LyricLine] listesi döner (zamana göre sıralı).
  static List<LyricLine> parse(String lrcText) {
    if (lrcText.isEmpty) return const [];

    final lines = lrcText.split('\n');
    final result = <LyricLine>[];

    // Regex: [mm:ss.xx] veya [mm:ss.xxx] veya [mm:ss] formatları
    final timeRegex = RegExp(
        r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]');

    for (final rawLine in lines) {
      String line = rawLine.trim();
      if (line.isEmpty) continue;

      // Çoklu zaman damgası: [00:10.00][00:15.00]Söz
      final matches = timeRegex.allMatches(line).toList();
      if (matches.isEmpty) continue;

      // Son zaman damgası sonrası gelen metni al
      final lastMatch = matches.last;
      final textStart = lastMatch.end;
      String text = line.substring(textStart).trim();

      // Metadata satırlarını atla (ti:, ar:, al:, by:, offset:, re:, ve:)
      final metaRegex = RegExp(r'^\[(ti|ar|al|by|offset|re|ve):');
      if (metaRegex.hasMatch(text)) continue;

      for (final match in matches) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final msStr = match.group(3) ?? '0';
        final milliseconds = msStr.length == 1
            ? int.parse(msStr) * 100
            : msStr.length == 2
                ? int.parse(msStr) * 10
                : int.parse(msStr);

        final time = Duration(
            minutes: minutes, seconds: seconds, milliseconds: milliseconds);

        if (text.isNotEmpty) {
          result.add(LyricLine(time: time, text: text));
        }
      }
    }

    // Zamana göre sırala
    result.sort((a, b) => a.time.compareTo(b.time));
    return result;
  }

  /// Sade metni (zaman damgaları olmadan) döner.
  static String toPlainText(List<LyricLine> lines) {
    return lines.map((l) => l.text).join('\n');
  }

  /// Verilen pozisyonda hangi satırın aktif olduğunu döner.
  static int getCurrentIndex(List<LyricLine> lines, Duration position) {
    int index = -1;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].time <= position) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }
}

/// Tek bir söz satırı: zaman + metin.
@immutable
class LyricLine {
  final Duration time;
  final String text;

  const LyricLine({required this.time, required this.text});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LyricLine &&
          runtimeType == other.runtimeType &&
          time == other.time &&
          text == other.text;

  @override
  int get hashCode => time.hashCode ^ text.hashCode;

  @override
  String toString() => 'LyricLine(time: $time, text: $text)';
}

/// Eşzamanlı söz widget'ı — oynatma pozisyonuna göre satırı vurgular.
class SyncedLyricsWidget extends StatelessWidget {
  const SyncedLyricsWidget({
    super.key,
    required this.lines,
    required this.position,
    this.textStyle = const TextStyle(
        fontSize: 16, color: Colors.white, height: 1.6),
    this.activeTextStyle = const TextStyle(
        fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
    this.backgroundTextStyle = const TextStyle(
        fontSize: 16, color: Colors.white54, height: 1.6),
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
  });

  final List<LyricLine> lines;
  final Duration position;
  final TextStyle textStyle;
  final TextStyle activeTextStyle;
  final TextStyle backgroundTextStyle;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return Padding(
        padding: padding,
        child: const Center(
          child: Text(
            'Şarkı sözü bulunamadı',
            style: TextStyle(color: Colors.white54, fontSize: 16),
          ),
        ),
      );
    }

    final currentIndex = LrcParser.getCurrentIndex(lines, position);

    return ListView.builder(
      padding: padding,
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final line = lines[index];
        final isActive = index == currentIndex;
        final isNext = index == currentIndex + 1;

        return AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: isActive
              ? activeTextStyle
              : (isNext ? textStyle : backgroundTextStyle),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              line.text,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      },
    );
  }
}
