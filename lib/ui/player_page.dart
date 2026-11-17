import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/download_service.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/theme_state.dart';
import '../screens/artist_page.dart';

String _fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
}

/// Full-screen playback view.
class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});

  void _openArtist(BuildContext context, Track track) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistPage(
          name: track.artist,
          channelId: track.artistId,
          seedTrack: track,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = PlayerController.instance;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Şimdi çalıyor'),
        centerTitle: true,
      ),
      body: ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          final track = player.current;
          if (track == null) {
            return const Center(child: Text('Çalan şarkı yok.'));
          }

          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: CachedNetworkImage(
                          imageUrl: track.thumb,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) =>
                              const Icon(Icons.music_note, size: 96),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    track.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: GestureDetector(
                    onTap: () => _openArtist(context, track),
                    child: Text(
                      track.artist,
                      style: TextStyle(
                        color: ThemeState.value.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (player.error != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.red.withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, color: Colors.redAccent),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Bu parça oynatılamadı. Başka parçaya geçilmedi.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                        TextButton(
                          onPressed: player.retry,
                          child: const Text('Tekrar dene'),
                        ),
                      ],
                    ),
                  ),
                _SeekBar(track: track),
                _Controls(track: track),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SeekBar extends StatelessWidget {
  const _SeekBar({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final player = PlayerController.instance;

    return StreamBuilder<Duration?>(
      stream: player.durationStream,
      builder: (context, duration) {
        final total = duration.data ?? track.duration ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: player.positionStream,
          builder: (context, position) {
            final pos = position.data ?? Duration.zero;
            final max = total.inMilliseconds.toDouble();
            final value = pos.inMilliseconds
                .toDouble()
                .clamp(0.0, max > 0 ? max : 1.0);

            return Column(
              children: [
                Slider(
                  value: value,
                  max: max > 0 ? max : 1.0,
                  onChanged: max > 0
                      ? (v) => player.seek(Duration(milliseconds: v.round()))
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmt(pos)),
                      Text(_fmt(total)),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final player = PlayerController.instance;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ListenableBuilder(
          listenable: Library.instance,
          builder: (context, _) {
            final liked = Library.instance.isLiked(track.id);
            return IconButton(
              tooltip: 'Beğen',
              icon: Icon(
                liked ? Icons.favorite : Icons.favorite_border,
                color: liked ? ThemeState.value : null,
              ),
              onPressed: () => Library.instance.toggleLike(track),
            );
          },
        ),
        const SizedBox(width: 4),
        IconButton(
          iconSize: 40,
          icon: const Icon(Icons.skip_previous),
          onPressed: player.previous,
        ),
        const SizedBox(width: 8),
        player.loading
            ? const SizedBox(
                width: 64,
                height: 64,
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              )
            : StreamBuilder<bool>(
                stream: player.playingStream,
                builder: (context, snap) => IconButton.filled(
                  iconSize: 48,
                  icon: Icon((snap.data ?? false)
                      ? Icons.pause
                      : Icons.play_arrow),
                  onPressed: player.toggle,
                ),
              ),
        const SizedBox(width: 8),
        IconButton(
          iconSize: 40,
          icon: const Icon(Icons.skip_next),
          onPressed: player.hasNext ? player.next : null,
        ),
        const SizedBox(width: 4),
        _DownloadButton(track: track),
      ],
    );
  }
}

class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final service = DownloadService.instance;

    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        if (service.isDownloading(track.id)) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                value: service.progressOf(track.id),
                strokeWidth: 2,
              ),
            ),
          );
        }

        final saved = service.savedPathOf(track.id) != null;
        return IconButton(
          tooltip: saved ? 'İndirildi' : 'İndir',
          icon: Icon(saved ? Icons.download_done : Icons.download_outlined),
          onPressed: () async {
            final messenger = ScaffoldMessenger.maybeOf(context);
            final path = await service.download(track);
            if (!context.mounted) return;
            messenger?.showSnackBar(
              SnackBar(
                content: Text(
                  path != null
                      ? 'Cihaza kaydedildi.'
                      : 'İndirme başarısız. Onarım botu yeniden deneyecek.',
                ),
              ),
            );
          },
        );
      },
    );
  }
}
