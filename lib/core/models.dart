class Track {
  final String id;
  final String title;
  final String artist;
  final Duration? duration;
  final String? artistId;

  const Track({
    required this.id,
    required this.title,
    required this.artist,
    this.duration,
    this.artistId,
  });

  /// Kapak görseli doğrudan YouTube görsel sunucusundan gelir.
  String get thumb => 'https://i.ytimg.com/vi/$id/hqdefault.jpg';

  String get watchUrl => 'https://www.youtube.com/watch?v=$id';

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'duration': duration?.inMilliseconds,
        'artistId': artistId,
      };

  factory Track.fromJson(Map<String, dynamic> json) => Track(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? 'Bilinmeyen',
        artist: json['artist'] as String? ?? 'Bilinmeyen',
        duration: json['duration'] == null
            ? null
            : Duration(milliseconds: json['duration'] as int),
        artistId: json['artistId'] as String?,
      );

  @override
  bool operator ==(Object other) => other is Track && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class PlaylistInfo {
  final String id;
  final String title;
  final String author;

  const PlaylistInfo({
    required this.id,
    required this.title,
    required this.author,
  });

  String get thumb => 'https://i.ytimg.com/vi/$id/hqdefault.jpg';
}
