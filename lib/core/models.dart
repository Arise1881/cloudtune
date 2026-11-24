import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;

/// YouTube kapaklarını listeler için küçük varyanta indirger.
/// `hqdefault`/`maxresdefault` gibi dosyalar 480–1280 px; 48–64 px'lik
/// tile'larda aynı görsel `mqdefault` (320x180) ile yüklenir. Mobil veride
/// kapak trafiği belirgin düşer, Wi-Fi'de de gereksiz indirme olmaz.
String compactThumbnailUrl(String url) {
  final uri = Uri.tryParse(url);
  final youtubeThumbHost = uri?.host.endsWith('ytimg.com') == true ||
      uri?.host.endsWith('youtube.com') == true;
  if (uri == null || !youtubeThumbHost) return url;
  final segments = uri.pathSegments;
  if (segments.length < 3 || segments[segments.length - 3] != 'vi') return url;
  if (segments.last == 'mqdefault.jpg') return uri.toString();
  return uri
      .replace(
        pathSegments: <String>[
          ...segments.sublist(0, segments.length - 1),
          'mqdefault.jpg',
        ],
      )
      .toString();
}

/// Windows'ta Invidious bazen göreli kapak URL'si döndürüyor; Dart bunu
/// çözümleyemediği için görsel boş kalıyordu. Parça kimliğinden canonical
/// YouTube CDN adresi üretilir. Diğer platformlar ve yerel/data kapaklar
/// dokunulmaz.
String _windowsCoverUrl(String? coverUrl, String id, String file) {
  if (defaultTargetPlatform != TargetPlatform.windows) {
    return coverUrl ?? 'https://i.ytimg.com/vi/$id/$file';
  }
  final uri = Uri.tryParse(coverUrl ?? '');
  if (uri != null &&
      uri.hasScheme &&
      (uri.scheme == 'file' ||
          uri.scheme == 'data' ||
          uri.host.toLowerCase().endsWith('ytimg.com') ||
          uri.host.toLowerCase().endsWith('youtube.com'))) {
    return coverUrl!;
  }
  return 'https://i.ytimg.com/vi/${Uri.encodeComponent(id)}/$file';
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
