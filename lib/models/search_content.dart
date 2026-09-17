/// YouTube/YouTube Music sanatçı arama sonucu.
class SearchArtist {
  final String id;
  final String name;
  final String thumbnailUrl;
  final int? subscriberCount;

  const SearchArtist({
    required this.id,
    required this.name,
    this.thumbnailUrl = '',
    this.subscriberCount,
  });

  String get subscriberLabel {
    final n = subscriberCount;
    if (n == null) return 'Kanal';
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)} M abone';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)} B abone';
    return '$n abone';
  }
}

/// YouTube/YouTube Music çalma listesi arama sonucu.
class PlaylistInfo {
  final String id;
  final String title;
  final int videoCount;
  final String thumbnailUrl;

  const PlaylistInfo({
    required this.id,
    required this.title,
    this.videoCount = 0,
    this.thumbnailUrl = '',
  });
}