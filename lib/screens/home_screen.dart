import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../models/song.dart';
import '../services/connectivity_service.dart';
import '../services/library_store.dart';
import '../services/music_service.dart';
import '../services/player_service.dart';
import '../services/room_service.dart';
import '../widgets/artwork.dart';
import 'library_screen.dart';
import 'now_playing_screen.dart';
import 'playlist_screen.dart';

/// Ana sayfa: selamlama, hızlı erişim kutucukları ve küratörlü bölümler.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final offline = context.watch<ConnectivityService>().isOffline;
    final library = context.watch<LibraryStore>();

    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _header(context)),
          if (offline) ...[
            const SliverToBoxAdapter(child: _OfflineHome()),
          ] else ...[
            SliverToBoxAdapter(child: _quickAccess(context, library)),
            _TrendSection(
              title: 'Türkçe Pop Hits',
              query: 'türkçe pop 2026 hit şarkılar',
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour < 6
        ? 'İyi geceler'
        : hour < 12
            ? 'Günaydın'
            : hour < 18
                ? 'İyi günler'
                : 'İyi akşamlar';

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            greeting,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(width: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Consumer<RoomService>(
                builder: (context, room, _) {
                  final inRoom = room.roomId != null;
                  return IconButton(
                    tooltip: 'Odalar',
                    icon: Icon(
                      inRoom ? Icons.groups : Icons.groups_outlined,
                      color: inRoom ? AppColors.accent : AppColors.textSecondary,
                    ),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const LibraryScreen(),
                        ),
                      );
                    },
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.person, color: AppColors.textSecondary),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const LibraryScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _quickAccess(BuildContext context, LibraryStore library) {
    final recents = library.recents;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          _songCard(
            context,
            title: 'Dinleme Geçmişi',
            subtitle: '${recents.length} şarkı',
            icon: Icons.history,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      PlaylistScreen(title: 'Dinleme Geçmişi', songs: recents),
                ),
              );
            },
          ),
          const SizedBox(width: 12),
          _songCard(
            context,
            title: 'İndirilenler',
            subtitle: '${library.downloads.length} şarkı',
            icon: Icons.download,
            onTap: () {
              LibraryScreen.openTab(context, 0);
            },
          ),
        ],
      ),
    );
  }

  Widget _songCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(icon, color: AppColors.accent, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.textSecondary,
                          ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios,
                  size: 16, color: AppColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Küratörlü bölüm: sorguyla şarkıları çeker, yatay kart listesi gösterir.
class _TrendSection extends StatefulWidget {
  const _TrendSection({required this.title, required this.query});

  final String title;
  final String query;

  @override
  State<_TrendSection> createState() => _TrendSectionState();
}

class _TrendSectionState extends State<_TrendSection> {
  late Future<List<Song>> _future;

  @override
  void initState() {
    super.initState();
    _future = MusicService.instance.search(widget.query, limit: 10);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Song>>(
      future: _future,
      builder: (context, snapshot) {
        final songs = snapshot.data ?? const <Song>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  if (songs.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PlaylistScreen(
                                title: widget.title, songs: songs),
                          ),
                        );
                      },
                      child: Text(
                        'Tümünü gör',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppColors.accent,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(
              height: 200,
              child: switch (snapshot.connectionState) {
                ConnectionState.waiting =>
                  const Center(child: CircularProgressIndicator()),
                ConnectionState.done when snapshot.hasError => Center(
                    child: Text(
                      'Bölüm yüklenemedi',
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                _ => ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: songs.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, i) => _TrendCard(
                      song: songs[i],
                      onTap: () {
                        context.read<PlayerService>().playQueue([songs[i]]);
                        Navigator.push(context, NowPlayingScreen.route(context));
                      },
                    ),
                  ),
              },
            ),
          ],
        );
      },
    );
  }
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.song, required this.onTap});

  final Song song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 140,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Artwork(url: song.thumbnailUrl, size: 140, radius: 10),
            ),
            const SizedBox(height: 8),
            Text(
              song.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Çevrimdışıyken ana sayfa: yalnızca indirilen şarkılar listelenir.
class _OfflineHome extends StatelessWidget {
  const _OfflineHome();

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryStore>();
    final downloads = library.downloads;

    if (downloads.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Henüz indirilen şarkı yok',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: min(5, downloads.length),
      itemBuilder: (context, index) {
        final song = downloads[index];
        return ListTile(
          leading: const Icon(Icons.file_download, color: AppColors.accent),
          title: Text(song.title),
          subtitle: Text('${song.durationLabel} • ${song.artist}'),
        );
      },
    );
  }
}