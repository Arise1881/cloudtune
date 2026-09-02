import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../models/song.dart';
import '../services/connectivity_service.dart';
import '../services/download_manager.dart';
import '../services/library_store.dart';
import '../services/music_service.dart';
import '../widgets/artwork.dart';
import 'library_screen.dart';
import 'playlist_screen.dart';
import 'settings_screen.dart';

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
            _SectionRow(title: 'Türkçe Pop Hits', query: 'türkçe pop 2026 hit şarkılar'),
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
          IconButton(
            icon: const Icon(Icons.person, color: AppColors.textSecondary),
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const LibraryScreen()));
            },
          ),
        ],
      ),
    );
  }

  Widget _quickAccess(BuildContext context, LibraryStore library) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          Expanded(
            child: _SongCard(
              title: 'Dinleme Geçmişi',
              subtitle: '${library.recentSongs.length} şarkı',
              icon: Icons.history,
              onTap: () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const RecentSongsScreen()));
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _SongCard(
              title: 'İndirilenler',
              subtitle: '${library.downloads.length} şarkı',
              icon: Icons.download,
              onTap: () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const DownloadedSongsScreen()));
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _SongCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
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
            const Icon(Icons.arrow_forward_ios, size: 16, color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }

  Widget _SectionRow({
    required String title,
    required String query,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            'Tümünü',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.accent,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
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
        child: Text(
          'Henüz indirilen şarkı yok',
          style: TextStyle(color: AppColors.textSecondary),
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
          subtitle: Text('${song.duration} - ${song.artist}'),
        );
      },
    );
  }
}