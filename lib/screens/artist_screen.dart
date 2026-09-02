import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../models/song.dart';
import '../services/download_manager.dart';
import '../services/library_store.dart';
import '../services/music_service.dart';
import '../services/player_service.dart';
import '../widgets/song_tile.dart';
import 'now_playing_screen.dart';
import 'song_actions.dart';

/// YouTube Music benzeri sanatçı sayfası.
class ArtistScreen extends StatefulWidget {
  const ArtistScreen({super.key, required this.artist});

  final String artist;

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  late Future<List<Song>> _future;
  String _stateTitle = '';

  @override
  void initState() {
    super.initState();
    _stateTitle = widget.artist;
    _future = MusicService.instance.artistSongs(widget.artist);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        title: const Text('Sanatçı',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: AppColors.card,
                        borderRadius: BorderRadius.circular(32),
                      ),
                      child: const Icon(Icons.person,
                          size: 36, color: AppColors.accent),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.artist,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800)),
                          const SizedBox(height: 4),
                          Text(_stateTitle.isEmpty
                              ? 'Diskografi'
                              : widget.artist,
                              style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          Expanded(
            child: FutureBuilder<List<Song>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(
                    child: CircularProgressIndicator(color: AppColors.accent),
                  );
                }
                if (snap.hasError || snap.data == null || snap.data!.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.person_off_outlined,
                            size: 48, color: AppColors.textSecondary),
                        const SizedBox(height: 12),
                        const Text('Şarkı bulunamadı',
                            style: TextStyle(color: AppColors.textSecondary)),
                        const SizedBox(height: 16),
                        OutlinedButton(
                          onPressed: () => setState(() {
                            _future =
                                MusicService.instance.artistSongs(widget.artist);
                          }),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.accent,
                            side: const BorderSide(color: AppColors.accent),
                          ),
                          child: const Text('Tekrar dene'),
                        ),
                      ],
                    ),
                  );
                }
                final songs = snap.data!;
                final player = PlayerService.instance;
                final library = context.watch<LibraryStore>();
                final downloader = context.watch<DownloadManager>();
                return ListView.separated(
                  padding: const EdgeInsets.only(bottom: 20),
                  itemCount: songs.length + 1,
                  separatorBuilder: (_, _) =>
                      const Divider(color: Colors.white12, height: 1),
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 48,
                              height: 48,
                              child: FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.accent,
                                  foregroundColor: Colors.black,
                                  shape: const CircleBorder(),
                                ),
                                child: const Icon(Icons.play_arrow),
                                onPressed: () {
                                  player.playQueue(songs);
                                  Navigator.of(context).push(
                                      NowPlayingScreen.route(context));
                                },
                              ),
                            ),
                            const SizedBox(width: 14),
                            Text('${songs.length} şarkı',
                                style: const TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 14)),
                          ],
                        ),
                      );
                    }
                    final song = songs[i - 1];
                    final isCurrent = player.current?.id == song.id;
                    return SongTile(
                      song: song,
                      selected: isCurrent,
                      downloadState: downloadStateFor(song, library, downloader),
                      onDownloadTap: downloader.isDownloading(song.id)
                          ? null
                          : () {
                              if (library.isDownloaded(song.id)) return;
                              downloader.download(song).catchError((_) {});
                            },
                      onTap: () async {
                        try {
                          player.playQueue(songs, startIndex: i - 1);
                          if (!context.mounted) return;
                          Navigator.of(context)
                              .push(NowPlayingScreen.route(context));
                        } catch (_) {}
                      },
                      onMenuTap: () => showSongActions(context, song),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
