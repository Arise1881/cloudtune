/// Resolves YouTube links. Five hosts are accepted: youtu.be,
/// m.youtube.com, youtube.com, www.youtube.com and music.youtube.com.
/// Watch, shorts, embed, live and v URLs are handled the same way.
class YoutubeLinkResolver {
  YoutubeLinkResolver._();

  static const Set<String> allowedHosts = {
    'youtu.be',
    'm.youtube.com',
    'youtube.com',
    'www.youtube.com',
    'music.youtube.com',
  };

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final RegExp _playlistPattern = RegExp(r'^[A-Za-z0-9_-]{10,64}$');

  static Uri? _parse(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'https://$text';
    try {
      final uri = Uri.parse(text);
      if (uri.host.isEmpty) return null;
      if (uri.scheme != 'http' && uri.scheme != 'https') return null;
      return uri;
    } catch (_) {
      return null;
    }
  }

  /// True when the text is a link on one of the allowed hosts.
  static bool isYoutubeLink(String input) {
    final uri = _parse(input);
    return uri != null && allowedHosts.contains(uri.host.toLowerCase());
  }

  /// Extracts the 11-character video id, or null when absent/invalid.
  static String? videoId(String input) {
    final uri = _parse(input);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    if (!allowedHosts.contains(host)) return null;

    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    String? candidate;
    if (host == 'youtu.be') {
      candidate = segments.isNotEmpty ? segments.first : null;
    } else if (segments.isNotEmpty && segments.first == 'watch') {
      candidate = uri.queryParameters['v'];
    } else if (segments.length >= 2 &&
        const {'shorts', 'embed', 'live', 'v'}.contains(segments.first)) {
      candidate = segments[1];
    }
    if (candidate != null && _idPattern.hasMatch(candidate)) return candidate;
    return null;
  }

  /// Extracts the playlist id from `list=...`, or null when absent/invalid.
  static String? playlistId(String input) {
    final uri = _parse(input);
    if (uri == null) return null;
    if (!allowedHosts.contains(uri.host.toLowerCase())) return null;
    final list = uri.queryParameters['list'];
    if (list != null && _playlistPattern.hasMatch(list)) return list;
    return null;
  }
}
