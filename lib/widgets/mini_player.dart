import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../screens/now_playing_screen.dart';
import '../services/download_manager.dart';
import '../services/library_store.dart';
import '../services/player_service.dart';

/// Alt gezinme çubuğunun üzerinde duran mini oynatıcı.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final song = player.current;
    if (song == null) return const SizedBox.shrink();

    return Dismissible(
      key: ValueKey('mini-${song.id}'),
      direction: DismissDirection.horizontal,
      onDismissed: (_) => player.pauseAndClose(),
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
        height: 58,
        decoration: BoxDecoration(
          color: AppColors.cardLight,
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 3)),
          ],
        ),
        child: Column(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () =>
                    Navigator.push(context, NowPlayingScreen.route(context)),
                child: Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 7),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: _MiniArt(song: song),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w600),
                          ),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.textSecondary, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: StreamBuilder<bool>(
                        stream: player.player.playerStateStream
                            .map((s) => s.playing),
                        initialData: player.player.playing,
                        builder: (_, snap) => Icon(
                          (snap.data ?? false) ? Icons.pause : Icons.play_arrow,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      onPressed: () {
                        if (player.isLoading) return;
                        player.togglePlayPause();
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next,
                          color: AppColors.textPrimary),
                      onPressed: () => player.next(),
                    ),
                  ],
                ),
              ),
            ),
            // İnce ilerleme çizgisi.
            StreamBuilder<Duration>(
              stream: player.player.positionStream,
              builder: (context, pos) {
                final duration =
                    player.player.duration ?? Duration(milliseconds: song.durationMs);
                final value = duration.inMilliseconds > 0
                    ? (pos.data?.inMilliseconds ?? 0) / duration.inMilliseconds
                    : 0.0;
                return LinearProgressIndicator(
                  value: value.clamp(0.0, 1.0),
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                  valueColor:
                      const AlwaysStoppedAnimation(AppColors.accentBright),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniArt extends StatelessWidget {
  const _MiniArt({required this.song});

  final dynamic song;

  // Yerel kapak yolu çözümünü önbellekle; her rebuild'de Future üretme.
  static final Map<String, String?> _artCache = {};

  @override
  Widget build(BuildContext context) {
    var local = _artCache[song.id];
    if (local == null) {
      try {
        final lib = LibraryStore.instance.downloadedSong(song.id);
        if (lib != null) {
          final f = File(DownloadManager.instance.artPath(song.id));
          if (f.existsSync()) {
            local = f.path;
          }
        }
      } catch (_) {}
      _artCache[song.id] = local;
    }
    final path = local;
    if (path != null && path.isNotEmpty) {
      return Image.file(File(path), width: 44, height: 44, fit: BoxFit.cover,
          cacheWidth: 132,
          errorBuilder: (_, _, _) => _net());
    }
    return _net();
  }

  Widget _net() {
    if (song.thumbnailUrl.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: song.thumbnailUrl,
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        memCacheWidth: 132,
        httpHeaders: const {'User-Agent': 'Mozilla/5.0'},
        errorWidget: (_, _, _) => Container(
          width: 44,
          height: 44,
          color: AppColors.card,
          child: const Icon(Icons.music_note, size: 18, color: AppColors.textSecondary),
        ),
      );
    }
    return Container(width: 44, height: 44, color: AppColors.card);
  }
}
