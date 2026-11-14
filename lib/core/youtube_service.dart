import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'models.dart';

/// Tüm istekler doğrudan YouTube'a gider (youtube.com / youtu.be).
/// Aracı sunucu, Cloudflare Worker veya tünel kullanılmaz.
class YoutubeService {
  YoutubeService._();
  static final YoutubeService instance = YoutubeService._();

  final YoutubeExplode _yt = YoutubeExplode();

  Track _fromVideo(Video v) => Track(
        id: v.id.value,
        title: v.title,
        artist: v.author,
        duration: v.duration,
      );

  Future<List<Track>> search(String query, {int limit = 24}) async {
    try {
      final results = await _yt.search.search(query);
      return results.take(limit).map(_fromVideo).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<Track> trackById(String id) async {
    final video = await _yt.videos.get(id);
    return _fromVideo(video);
  }

  Future<List<Track>> playlist(String id, {int limit = 50}) async {
    final out = <Track>[];
    try {
      await for (final video in _yt.playlists.getVideos(id)) {
        out.add(_fromVideo(video));
        if (out.length >= limit) break;
      }
    } catch (_) {}
    return out;
  }

  /// En yüksek bit hızlı ses akışının adresini döndürür.
  Future<Uri> audioUri(String id) async {
    final manifest = await _yt.videos.streamsClient.getManifest(id);
    final audio = manifest.audioOnly;
    if (audio.isEmpty) {
      throw StateError('Bu video için ses akışı bulunamadı.');
    }
    return audio.withHighestBitrate().url;
  }
}
