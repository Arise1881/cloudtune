import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;

/// YouTube kapaklarını listeler için küçük varyanta indirger.
/// `hqdefault`/`maxresdefault` gibi dosyalar 480–1280 px; 48–64 px'lik
/// tile'larda aynı görsel `mqdefault` (320x180) ile yüklenir. Mobil veride
/// kapak trafiği belirgin düşer, Wi-Fi'de de gereksiz indirme olmaz.
String compactThumbnailUrl(String url) {
  var raw = url.trim();
  if (raw.isEmpty) return raw;
  if (raw.startsWith('//')) raw = 'https:$raw';
  if (raw.startsWith('/')) {
    raw = raw.startsWith('/vi/')
        ? 'https://i.ytimg.com$raw'
        : 'https://www.youtube.com$raw';
  }
  final uri = Uri.tryParse(raw);
  final youtubeThumbHost = uri?.host.endsWith('ytimg.com') == true ||
      uri?.host.endsWith('youtube.com') == true;
  if (uri == null || !youtubeThumbHost) return raw;
  final segments = uri.pathSegments;
  if (segments.length < 3 || segments[segments.length - 3] != 'vi') return raw;
  if (segments.last == 'mqdefault.jpg') return uri.toString();
  return uri
      .replace(
        scheme: uri.scheme.isEmpty ? 'https' : uri.scheme,
        pathSegments: <String>[
          ...segments.sublist(0, segments.length - 1),
          'mqdefault.jpg',
        ],
      )
      .toString();
}

/// Bazı kaynaklar (Invidious/YouTube Music) göreli veya protokol-göreli kapak
/// URL'si döndürebiliyor; Linux/desktop'ta bu görselin boş kalmasına neden olur.
/// Mutlak http/https/file/data URL'ler korunur; göreli URL'ler normalize edilir;
/// boş/geçersiz durumda YouTube CDN vi fallback kullanılır.
String _windowsCoverUrl(String? coverUrl, String id, String file) {
  final fallback = 'https://i.ytimg.com/vi/${Uri.encodeComponent(id)}/$file';
  var raw = (coverUrl ?? '').trim();
  if (raw.isEmpty) return fallback;
  if (raw.startsWith('//')) raw = 'https:$raw';
  if (raw.startsWith('/')) {
    raw = raw.startsWith('/vi/')
        ? 'https://i.ytimg.com$raw'
        : 'https://www.youtube.com$raw';
  }
  final uri = Uri.tryParse(raw);
  if (uri == null) return fallback;
  if (uri.scheme == 'file' || uri.scheme == 'data') return raw;
  if ((uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty) {
    return raw;
  }
  return fallback;
}

class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    this.duration,
    this.artistId,
    this.sourceUrl,
    this.coverUrl,
  });

  final String id;
  final String title;
  final String artist;
  final Duration? duration;
  final String? artistId;

  /// Doğrudan ses adresi. Test parçaları YouTube yerine bunu kullanır.
  final String? sourceUrl;

  /// Özel kapak adresi; yoksa YouTube miniature düşülür.
  final String? coverUrl;

  /// UI ve medya bildirimi için bant genişliği dostu kapak.
  String get thumb => compactThumbnailUrl(
        _windowsCoverUrl(coverUrl, id, 'mqdefault.jpg'),
      );

  /// Büyük kapak gerektiren yerler için orijinal URL korunur.
  String get artwork => _windowsCoverUrl(coverUrl, id, 'hqdefault.jpg');

  String get watchUrl => 'https://www.youtube.com/watch?v=$id';

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'duration': duration?.inMilliseconds,
        'artistId': artistId,
        'sourceUrl': sourceUrl,
        'coverUrl': coverUrl,
      };

  factory Track.fromJson(Map<String, dynamic> json) => Track(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? 'Bilinmeyen',
        artist: json['artist'] as String? ?? 'Bilinmeyen',
        duration: json['duration'] == null
            ? null
            : Duration(milliseconds: (json['duration'] as num).toInt()),
        artistId: json['artistId'] as String?,
        sourceUrl: json['sourceUrl'] as String?,
        coverUrl: json['coverUrl'] as String?,
      );

  Track copyWith({
    String? id,
    String? title,
    String? artist,
    Duration? duration,
    String? artistId,
    String? sourceUrl,
    String? coverUrl,
  }) =>
      Track(
        id: id ?? this.id,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        duration: duration ?? this.duration,
        artistId: artistId ?? this.artistId,
        sourceUrl: sourceUrl ?? this.sourceUrl,
        coverUrl: coverUrl ?? this.coverUrl,
      );

  @override
  bool operator ==(Object other) => other is Track && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Track($id, $title)';
}

class PlaylistInfo {
  const PlaylistInfo({
    required this.id,
    required this.title,
    required this.author,
    this.thumbUrl,
  });

  final String id;
  final String title;
  final String author;

  /// Liste kimliği video kimliği değildir; kapak yalnızca gerçek bir parça
  /// veya API'nin döndürdüğü görselden gelir. Boşsa UI placeholder gösterir.
  final String? thumbUrl;

  String? get thumb => (thumbUrl == null || thumbUrl!.isEmpty)
      ? null
      : compactThumbnailUrl(thumbUrl!);
}
