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

/// Sanatçı sayfası: sanatçı şarkılarını listeler.
class ArtistScreen extends StatefulWidget {
  const ArtistScreen({super.key, required this.name, this.thumbnailUrl});

  final String name;
  final String? thumbnailUrl;

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  List<Song> _songs = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final songs =
          await MusicService.instance.artistSongs(widget.name, limit: 40);
      if (!mounted) return;
      setState(() => _songs = songs);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Şarkılar yüklenemedi. Bağlantını kontrol et.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final artUrl = widget.thumbnailUrl;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            backgroundColor: AppColors.gradientTop,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
              onPressed: () => Navigator.of(context).pop(),
            ),
            flexibleSpace: FlexibleSpaceBar(
              title: Text(widget.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w800)),
              centerTitle: true,
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [AppColors.gradientTop, AppColors.background],
                  ),
                ),
                child: Center(
                  child: CircleAvatar(
                    radius: 48,
                    backgroundColor: AppColors.cardLight,
                    backgroundImage:
                        artUrl != null && artUrl.isNotEmpty
                            ? NetworkImage(artUrl)
                            : null,
                    child: artUrl == null || artUrl.isEmpty
                        ? const Icon(Icons.person,
                            size: 48, color: AppColors.textSecondary)
                        : null,
                  ),
                ),
              ),
            ),
          ),
          if (_loading)
            const SliverFillRemaining(
              child: Center(
                child: CircularProgressIndicator(color: AppColors.accentBright),
              ),
            )
          else if (_error != null)
            SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline,
                          size: 46, color: AppColors.textSecondary),
                      const SizedBox(height: 12),
                      Text(_error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 15)),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: _load,
                        child: const Text('Tekrar Dene'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (_songs.isEmpty)
            const SliverFillRemaining(
              child: Center(
                child: Text('Şarkı bulunamadı',
                    style:
                        TextStyle(color: AppColors.textSecondary, fontSize: 15)),
              ),
            )
          else
            SliverList.builder(
              itemCount: _songs.length,
              itemBuilder: (context, i) {
                final song = _songs[i];
                final player = context.read<PlayerService>();
                final downloads = context.watch<DownloadManager>();
                final library = context.watch<LibraryStore>();
                final isCurrent = player.current?.id == song.id;
                final isDownloaded = library.isDownloaded(song.id);
                final progress = downloads.progress[song.id];
                return SongTile(
                  song: song,
                  selected: isCurrent,
                  downloadState: isDownloaded
                      ? true
                      : (downloads.isDownloading(song.id)
                          ? (progress ?? 0.0)
                          : const NoDownloadState()),
                  onDownloadTap: () {
                    if (!isDownloaded && !downloads.isDownloading(song.id)) {
                      downloads.download(song).catchError((_) {});
                    }
                  },
                  onTap: () {
                    player.playQueue(_songs, startIndex: i);
                    if (!context.mounted) return;
                    Navigator.of(context).push(NowPlayingScreen.route(context));
                  },
                  onMenuTap: () => showSongActions(context, song),
                );
              },
            ),
        ],
      ),
    );
  }
}