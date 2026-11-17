import 'library.dart';
import 'link_resolver.dart';
import 'models.dart';
import 'player_controller.dart';
import 'repair_bot.dart';
import 'youtube_service.dart';

/// Opens an allowed YouTube link and starts playback. Failures stay silent:
/// the caller receives `false`, no error is shown to the user, and the failure
/// is only logged quietly through [RepairBot].
class LinkHandler {
  LinkHandler._();

  /// Whether the app handles shared YouTube links internally.
  static bool get enabled => Library.instance.linkHandlerEnabled;

  static Future<bool> _fail(String raw) async {
    try {
      await RepairBot.instance.reportEvent('link_open_failed', {'link': raw});
    } catch (_) {}
    return false;
  }

  static Future<bool> open(String raw) async {
    if (!enabled) return await _fail(raw);

    final videoId = YoutubeLinkResolver.videoId(raw);
    final playlistId = YoutubeLinkResolver.playlistId(raw);
    final youtube = YoutubeService.instance;
    final player = PlayerController.instance;

    try {
      if (playlistId != null) {
        final tracks = await youtube.playlist(playlistId, seed: videoId);
        if (tracks.isNotEmpty) {
          var start = 0;
          if (videoId != null) {
            final found = tracks.indexWhere((t) => t.id == videoId);
            if (found >= 0) start = found;
          }
          await player.playQueue(tracks, start);
          return true;
        }
        if (videoId == null) return await _fail(raw);
      }

      if (videoId != null) {
        final Track track = await youtube.trackById(videoId);
        await player.playQueue([track], 0);
        return true;
      }
      return await _fail(raw);
    } catch (_) {
      return await _fail(raw);
    }
  }
}
