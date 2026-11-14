class Track {
  final String id;
  final String title;
  final String artist;
  final Duration? duration;

  const Track({
    required this.id,
    required this.title,
    required this.artist,
    this.duration,
  });

  /// Kapak görseli doğrudan YouTube görsel sunucusundan gelir.
  String get thumb => 'https://i.ytimg.com/vi/$id/hqdefault.jpg';

  String get watchUrl => 'https://www.youtube.com/watch?v=$id';
}
