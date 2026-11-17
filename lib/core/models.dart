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

  String get thumb => coverUrl ?? 'https://i.ytimg.com/vi/$id/hqdefault.jpg';

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
  });

  final String id;
  final String title;
  final String author;

  String get thumb => 'https://i.ytimg.com/vi/$id/hqdefault.jpg';
}
