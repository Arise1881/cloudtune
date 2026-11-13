import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../models/song.dart';
import '../services/connectivity_service.dart';
import '../services/library_store.dart';
import '../services/music_service.dart';
import '../services/player_service.dart';
import '../services/repair_bot_service.dart';
import '../widgets/artwork.dart';
import '../widgets/update_banner.dart';
import 'library_screen.dart';
import 'now_playing_screen.dart';
import 'playlist_screen.dart';

/// Spotify klonu ana sayfa: selamlama, Sana Özel, Son Çalınanlar,
/// Kütüphane hızlı erişimi, Kategoriler ve En Popüler bölümleri.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  Timer? _refreshTimer;
  int _refreshCounter = 0;

  @override
  void initState() {
    super.initState();
    RepairBotService.instance.initialize();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() => _refreshCounter++);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void refreshNow() {
    if (!mounted) return;
    MusicService.bustHomeCache();
    setState(() => _refreshCounter++);
  }

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 6) return 'İyi geceler';
    if (h < 12) return 'Günaydın';
    if (h < 18) return 'İyi günler';
    return 'İyi akşamlar';
  }

  @override
  Widget build(BuildContext context) {
    final offline = context.watch<ConnectivityService>().isOffline;
    final library = context.watch<LibraryStore>();
    final refreshTrigger = _refreshCounter;

    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: UpdateBanner()),

          // Sabit üst bar: selamlama + ikonlar (kaydırılmaz).
          SliverPersistentHeader(
            pinned: true,
            delegate: _HeaderDelegate(
              greeting: _greeting(),
              onRefresh: refreshNow,
            ),
          ),

          // Boşluk (header aşağıda kalsın diye).
          const SliverToBoxAdapter(child: SizedBox(height: 12)),

          // Sana Özel bölüm.
          if (!offline)
            _MadeForYouSection(refreshTrigger: refreshTrigger),

          // Son Çalınanlar.
          const SliverToBoxAdapter(child: SizedBox(height: 4)),
          if (library.recents.isNotEmpty)
            SliverToBoxAdapter(
              child: _sectionRow(
                title: AppStrings.recentlyPlayed,
                subtitle: '${library.recents.length} şarkı',
                onAll: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PlaylistScreen(
                      title: 'Son Çalınanlar',
                      songs: library.recents,
                      fetcher: (_) => Future.value(library.recents),
                    ),
                  ),
                ),
                children: _songChips(context, library.recents.take(6).toList()),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
          SliverToBoxAdapter(
            child: _LibraryQuickAccess(library: library),
          ),

          // Kategoriler.
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
          SliverToBoxAdapter(
            child: _CategoriesSection(),
          ),

          // En Popüler (küratörlü).
          if (!offline)
            SliverToBoxAdapter(
              child: _TopChartsSection(refreshTrigger: refreshTrigger),
            ),

          // Alt boşluk (mini player için).
          const SliverToBoxAdapter(child: SizedBox(height: 90)),
        ],
      ),
    );
  }

  // ─── Şarkı kareleri (yatay) ───

  Widget _sectionRow({
    required String title,
    required String subtitle,
    required VoidCallback onAll,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              TextButton(
                onPressed: onAll,
                child: const Text(
                  'Tümünü gör',
                  style: TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 220,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: children,
          ),
        ),
      ],
    );
  }

  List<Widget> _songChips(BuildContext context, List<Song> songs) {
    final player = context.read<PlayerService>();
    return songs.map((s) {
      return GestureDetector(
        onTap: () {
          player.playQueue(songs, startIndex: songs.indexOf(s));
          Navigator.push(context, NowPlayingScreen.route(context));
        },
        child: SizedBox(
          width: 150,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Artwork(
                      url: s.thumbnailUrl,
                      size: 150,
                      radius: 10,
                    ),
                  ),
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        s.durationLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                s.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                s.artist,
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
    }).toList();
  }

  // ─── Sana Özel bölüm ───
}

class _MadeForYouSection extends StatelessWidget {
  const _MadeForYouSection({required this.refreshTrigger});

  final int refreshTrigger;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              AppStrings.madeForYou,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(
            height: 230,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: curatedSections.length,
              itemBuilder: (_, i) {
                final entry = curatedSections.entries.elementAt(i);
                return _MixCard(
                  title: entry.key,
                  query: entry.value,
                  index: i,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MixCard extends StatelessWidget {
  const _MixCard({required this.title, required this.query, required this.index});

  final String title;
  final String query;
  final int index;

  final List<List<Color>> _gradients = const [
    [Color(0xFF6A11CB), Color(0xFF2575FC)],
    [Color(0xFF11998E), Color(0xFF38EF7D)],
    [Color(0xFFFC466B), Color(0xFF3F5EFB)],
    [Color(0xFFFDCD32), Color(0xFFFFED4B)],
    [Color(0xFF203A43), Color(0xFF2C5364)],
    [Color(0xFF8E2DE2), Color(0xFF4A00E0)],
    [Color(0xFF4B6CB7), Color(0xFF182848)],
    [Color(0xFF141E30), Color(0xFF243B55)],
  ];

  @override
  Widget build(BuildContext context) {
    final colors = _gradients[index % _gradients.length];
    final player = context.read<PlayerService>();

    return GestureDetector(
      onTap: () {
        // Karışık mix başlat: arama sonucundan ilk 30 şarkı alıp sırayla çalar.
        _startMix(context, player, query, title);
      },
      child: SizedBox(
        width: 170,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 170,
              height: 170,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: colors,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: colors[0].withValues(alpha: 0.5),
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.auto_awesome,
                      color: Colors.white,
                      size: 48,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Mix',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Karışık · ${query.toUpperCase()}',
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

  void _startMix(BuildContext context, PlayerService player, String query, String title) {
    // Karışık mix için YouTube araması yapıp sırayla çalar.
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text('$title başlatılıyor…',
            style: const TextStyle(color: AppColors.textPrimary)),
        content: const SizedBox(
          height: 80,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppColors.accent),
              SizedBox(height: 10),
              Text('Şarkılar hazırlanıyor…',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
    unawaited(_loadMix(context, player, query, title));
  }

  Future<void> _loadMix(BuildContext context, PlayerService player, String query, String title) async {
    try {
      final songs = await MusicService.instance.search(query, limit: 30);
      if (!context.mounted) return;
      Navigator.pop(context);
      if (songs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Mix için şarkı bulunamadı.'),
          duration: Duration(seconds: 2),
        ));
        return;
      }
      player.playQueue(songs, startIndex: 0);
      Navigator.push(context, NowPlayingScreen.route(context));
    } catch (_) {
      if (!context.mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Mix başlatılamadı.'),
        duration: Duration(seconds: 2),
      ));
    }
  }
}

// ─── Kütüphane hızlı erişim ───

class _LibraryQuickAccess extends StatelessWidget {
  const _LibraryQuickAccess({required this.library});

  final LibraryStore library;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text(
            AppStrings.yourLibrary,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _Pill(
                icon: Icons.library_music,
                label: 'Çalma Listeleri',
                count: library.playlists.length,
                onTap: () => LibraryScreen.openTab(context, 0),
              ),
              const SizedBox(width: 10),
              _Pill(
                icon: Icons.person,
                label: 'Sanatçılar',
                count: library.artists.length,
                onTap: () => LibraryScreen.openTab(context, 1),
              ),
              const SizedBox(width: 10),
              _Pill(
                icon: Icons.favorite,
                label: AppStrings.likedSongs,
                count: library.likedSongs.length,
                onTap: () => LibraryScreen.openTab(context, 3),
              ),
              const SizedBox(width: 10),
              _Pill(
                icon: Icons.download,
                label: 'İndirilenler',
                count: library.downloads.length,
                onTap: () => LibraryScreen.openTab(context, 0),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 95,
        height: 95,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.cardHover,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: AppColors.accent, size: 24),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '$count',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Kategoriler ───

class _CategoriesSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final categories = [
      ('Pop', Icons.music_note),
      ('Rock', Icons.music_off),
      ('Rap / Hip-Hop', Icons.mic),
      ('Elektronik', Icons.science),
      ('Jazz', Icons.music_video),
      ('Klasik', Icons.music_off),
      ('R&B', Icons.favorite),
      ('Country', Icons.terrain),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text(
            AppStrings.categories,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: categories.map((c) {
              return FilterChip(
                label: Text(c.$1,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    )),
                avatar: Icon(c.$2, size: 16, color: AppColors.textSecondary),
                selectedColor: AppColors.accent,
                checkmarkColor: Colors.black,
                backgroundColor: AppColors.card,
                labelPadding: const EdgeInsets.symmetric(horizontal: 14),
                padding: EdgeInsets.zero,
                onSelected: (_) {
                  // Kategori araması yap.
                },
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

// ─── En Popüler ───

class _TopChartsSection extends StatelessWidget {
  const _TopChartsSection({required this.refreshTrigger});

  final int refreshTrigger;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text(
            AppStrings.topCharts,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 220,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: 10,
            itemBuilder: (_, i) => _ChartCard(rank: i + 1),
          ),
        ),
      ],
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.rank});

  final int rank;

  @override
  Widget build(BuildContext context) {
    final colors = [
      const Color(0xFF1DB954),
      const Color(0xFFB3B3B3),
      const Color(0xFFCD7F32),
      const Color(0xFF808080),
      const Color(0xFF808080),
      const Color(0xFF808080),
      const Color(0xFF808080),
      const Color(0xFF808080),
      const Color(0xFF808080),
      const Color(0xFF808080),
    ];

    return Container(
      width: 160,
      margin: const EdgeInsets.only(right: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 160,
                  height: 150,
                  color: AppColors.cardHover,
                  child: Center(
                    child: Icon(
                      Icons.music_note,
                      color: AppColors.textSecondary,
                      size: 40,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '#$rank',
                    style: TextStyle(
                      color: colors[rank - 1],
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Şarkı Başlığı',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'Sanatçı Adı',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Sabit başlatma ───

class _HeaderDelegate extends SliverPersistentHeaderDelegate {
  const _HeaderDelegate({
    required this.greeting,
    required this.onRefresh,
  });

  final String greeting;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  greeting,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Ne dinlemek istersin?',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.accent, size: 22),
            tooltip: 'Yenile',
            onPressed: onRefresh,
          ),
          IconButton(
            icon: const Icon(Icons.person_outline, color: AppColors.textSecondary, size: 22),
            tooltip: 'Kütüphane',
            onPressed: () => LibraryScreen.openTab(context, 0),
          ),
        ],
      ),
    );
  }

  @override
  double get maxExtent => 100;

  @override
  double get minExtent => 80;

  @override
  bool shouldRebuild(covariant _HeaderDelegate old) =>
      old.greeting != greeting;
}
