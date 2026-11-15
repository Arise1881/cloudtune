import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'cloudflare.dart';
import 'models.dart';

/// Tüm istekler dogrudan YouTube'a gider (youtube.com / youtu.be).
/// Aracı sunucu, Cloudflare Worker veya tunel kullanılmaz; yalnızca akis
/// tamamen basarisiz olursa sessiz yedek kanal devreye girer.
class YoutubeService {
  YoutubeService._();
  static final YoutubeService instance = YoutubeService._();

  final YoutubeExplode _yt = YoutubeExplode();

  Track _fromVideo(Video v) => Track(
        id: v.id.value,
        title: v.title,
        artist: v.author,
        duration: v.duration,
        artistId: v.channelId.value.isEmpty ? null : v.channelId.value,
      );

  Future<List<Track>> search(String query, {int limit = 24}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    try {
      final results = await _yt.search.search(q);
      return results.take(limit).map(_fromVideo).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<Track> trackById(String id) async {
    final video = await _yt.videos.get(id);
    return _fromVideo(video);
  }

  /// Calma listesi. Mix/radyo listelerinde (`RD...`) video kimligi de
  /// verilirse, liste cozulemezse ilgili videolara duser.
  Future<List<Track>> playlist(String id, {int limit = 200, String? seed}) async {
    final out = <Track>[];
    try {
      await for (final video in _yt.playlists.getVideos(id)) {
        final t = _fromVideo(video);
        if (t.id.isEmpty || t.title.trim().isEmpty) continue;
        out.add(t);
        if (out.length >= limit) break;
      }
    } catch (_) {
      // Asagidaki yedeklere gec.
    }
    if (out.isEmpty && seed != null) {
      return related(seed, limit: limit);
    }
    return out;
  }

  Future<PlaylistInfo?> playlistInfo(String id) async {
    try {
      final p = await _yt.playlists.get(id);
      return PlaylistInfo(id: p.id.value, title: p.title, author: p.author);
    } catch (_) {
      return null;
    }
  }

  /// Sonsuz radyo: bir videonun ilgili videolari.
  Future<List<Track>> related(String videoId, {int limit = 30}) async {
    try {
      final video = await _yt.videos.get(videoId);
      final rel = await _yt.videos.getRelatedVideos(video);
      if (rel == null) return const [];
      return rel.take(limit).map(_fromVideo).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Sanatci profili: kanal yuklemeleri; kanal kimligi yoksa isim aramasi.
  Future<List<Track>> artistTracks(String name, {String? channelId, int limit = 60}) async {
    if (channelId != null && channelId.isNotEmpty) {
      try {
        final out = <Track>[];
        await for (final video in _yt.channels.getUploads(ChannelId(channelId))) {
          out.add(_fromVideo(video));
          if (out.length >= limit) break;
        }
        if (out.isNotEmpty) return out;
      } catch (_) {}
    }
    return search('$name en iyi sarkilar', limit: limit);
  }

  /// En yuksek bit hizli ses akisi. Dogrudan basarisiz olursa yedek kanal.
  Future<Uri> audioUri(String id) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final manifest = await _yt.videos.streamsClient.getManifest(id);
        final audio = manifest.audioOnly;
        if (audio.isEmpty) continue;
        return audio.withHighestBitrate().url;
      } catch (e) {
        lastError = e;
      }
    }
    final fallback = await CloudflareFallback.audioUrl(id);
    if (fallback != null) return fallback;
    throw StateError('audio-unavailable: ${lastError ?? id}');
  }
}
