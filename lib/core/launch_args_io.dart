import 'dart:io';

const List<String> _mediaExtensions = <String>[
  '.mp3',
  '.m4a',
  '.mp4',
  '.aac',
  '.flac',
  '.ogg',
  '.opus',
  '.wav',
  '.webm',
];

/// Windows "Şununla aç" çağrısında gelen ilk yerel medya yolunu döner.
/// Flutter masaüstünde komut satırı argümanları `dart:io` üzerinden okunur.
String? initialMediaPath() {
  try {
    for (final arg in Platform.executableArguments) {
      if (arg.startsWith('-')) continue;
      if (!arg.contains('\\') && !arg.contains('/')) continue;
      final lower = arg.toLowerCase();
      if (_mediaExtensions.any(lower.endsWith)) return arg;
    }
  } catch (_) {
    // Komut satırı erişimi yoksa sessizce geç.
  }
  return null;
}
