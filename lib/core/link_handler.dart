import 'library.dart';
import 'link_resolver.dart';
import 'models.dart';
import 'player_controller.dart';
import 'youtube_service.dart';

/// Bir YouTube baglantisini (youtu.be, m.youtube.com, youtube.com,
/// www.youtube.com) acip calar. Kullaniciya hata bilgisi gosterilmez;
/// basarisizlikta null doner ve onarim botu devralir.
class LinkHandler {
  LinkHandler._();

  /// Android'de "Desteklenen baglantilar" anahtari. Kapaliysa uygulama
  /// YouTube baglantilarini icerde acmaz.
  static bool get enabled => Library.instance.linkHandlerEnabled;

  static Future<bool> open(String raw) async {
    if (!enabled) return false;
    final videoId = YoutubeLinkResolver.videoId(raw);
    final playlistId = YoutubeLinkResolver.playlistId(raw);
    final yt = YoutubeService.instance;
    final player = PlayerController.instance;

    try {
      if (playlistId != null) {
        final tracks = await yt.playlist(playlistId, seed: videoId);
        if (tracks.isNotEmpty) {
          var start = 0;
          if (videoId != null) {
            final found = tracks.indexWhere((t) => t.id == videoId);
            if (found >= 0) start = found;
          }
          await player.playQueue(tracks, start);
          return true;
        }
        if (videoId == null) return false;
      }
      if (videoId != null) {
        final Track track = await yt.trackById(videoId);
        await player.playQueue([track], 0);
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}
