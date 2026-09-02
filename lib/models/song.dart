import 'dart:convert';

class Song {
  final String id;
  final String title;
  final String artist;
  final String thumbnailUrl;
  final int durationMs;
  final String? localPath;
  final int downloadedAtMs;

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    this.thumbnailUrl = '',
    this.durationMs = 0,
    this.localPath,
    this.downloadedAtMs = 0,
  });

  bool get isDownloaded => localPath != null && localPath!.isNotEmpty;

  Song copyWith({
    String? id,
    String? title,
    String? artist,
    String? thumbnailUrl,
    int? durationMs,
    String? localPath,
    int? downloadedAtMs,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      durationMs: durationMs ?? this.durationMs,
      localPath: localPath ?? this.localPath,
      downloadedAtMs: downloadedAtMs ?? this.downloadedAtMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'thumbnailUrl': thumbnailUrl,
        'durationMs': durationMs,
        'localPath': localPath,
        'downloadedAtMs': downloadedAtMs,
      };

  factory Song.fromJson(Map<String, dynamic> json) => Song(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? 'Bilinmeyen',
        artist: json['artist'] as String? ?? '',
        thumbnailUrl: json['thumbnailUrl'] as String? ?? '',
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        localPath: json['localPath'] as String?,
        downloadedAtMs: (json['downloadedAtMs'] as num?)?.toInt() ?? 0,
      );

  static List<Song> listFromJson(String raw) {
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  static String listToJson(List<Song> songs) =>
      jsonEncode(songs.map((s) => s.toJson()).toList());

  @override
  bool operator ==(Object other) => other is Song && other.id == id;

  @override
  int get hashCode => id.hashCode;

  String get durationLabel {
    if (durationMs <= 0) return '--:--';
    final d = Duration(milliseconds: durationMs);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
