import 'link_resolver.dart';
import 'models.dart';
import 'player_controller.dart';
import 'youtube_service.dart';

/// Bir YouTube bağlantısını (youtu.be, m.youtube.com, youtube.com,
/// www.youtube.com) açıp çalar. Hata varsa kullanıcıya gösterilecek
/// mesajı, başarılıysa null döndürür.
class LinkHandler {
  LinkHandler._();

  static Future<String?> open(String raw) async {
    final videoId = YoutubeLinkResolver.videoId(raw);
    final playlistId = YoutubeLinkResolver.playlistId(raw);
    final yt = YoutubeService.instance;
    final player = PlayerController.instance;

    try {
      if (playlistId != null) {
        final tracks = await yt.playlist(playlistId);
        if (tracks.isNotEmpty) {
          var start = 0;
          if (videoId != null) {
            final found = tracks.indexWhere((t) => t.id == videoId);
            if (found >= 0) start = found;
          }
          await player.playQueue(tracks, start);
          return null;
        }
        if (videoId == null) return 'Çalma listesi boş veya erişilemiyor.';
      }
      if (videoId != null) {
        final Track track = await yt.trackById(videoId);
        await player.playQueue([track], 0);
        return null;
      }
      return 'Geçerli bir YouTube bağlantısı bulunamadı.';
    } catch (e) {
      return 'Bağlantı açılamadı. İnternetini kontrol edip tekrar dene.';
    }
  }
}
