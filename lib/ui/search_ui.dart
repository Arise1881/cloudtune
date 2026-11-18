import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/app_palette.dart';
import '../core/models.dart';
import '../core/theme_state.dart';

/// Müsify benzeri arama ekranının sabitleri ve saf yardımcıları.
class SearchUi {
  const SearchUi._();

  /// "Ara" başlığı ve bölüm ikonları. Kullanıcı vurgu rengini değiştirdiğinde
  /// arama ekranı da aynı renge geçer; varsayılan açık mavi temadır.
  static Color get titleAccent => ThemeState.value;

  /// Aktif alt menü ovali de aynı vurgu rengini kullanır.
  static Color get activeAccent => ThemeState.value;

  /// Koyu gri yuvarlatılmış arama çubuğu.
  static const Color fieldFill = Color(0xFF242424);

  static const List<String> trackActions = <String>[
    'play',
    'radio',
    'like',
    'download',
    'artist',
    'playlist',
  ];

  /// `Duration` değerini kapak rozetinde gösterilecek biçime çevirir.
  /// Örnek: 34 sn -> `00:34`, 1 sn 0 dk 14 sn -> `1:00:14`.
  static String durationLabel(Duration? duration) {
    if (duration == null || duration.inSeconds < 0) return '--:--';
    final total = duration.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
  }

  /// Arama sonuçlarından tekil sanatçı kartları üretir.
  /// Kanal ID varsa sanatçı adından önce gelir; aynı ad farklı kanallar
  /// farklı kart olabilir.
  static List<Track> artistSeeds(List<Track> tracks) {
    final seen = <String>{};
    final seeds = <Track>[];
    for (final track in tracks) {
      final name = track.artist.trim();
      if (name.isEmpty) continue;
      final key = (track.artistId != null && track.artistId!.trim().isNotEmpty)
          ? 'id:${track.artistId!.trim()}'
          : 'name:${name.toLowerCase()}';
      if (seen.add(key)) seeds.add(track);
    }
    return seeds;
  }
}

class SearchTitle extends StatelessWidget {
  const SearchTitle({super.key, this.title = 'Ara'});

  final String title;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: SearchUi.titleAccent,
            fontSize: 24,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class SearchSectionTitle extends StatelessWidget {
  const SearchSectionTitle({
    super.key,
    required this.icon,
    required this.title,
    this.trailing,
    this.onPlayAll,
    this.onSave,
    this.onDownload,
  });

  final IconData icon;
  final String title;
  final String? trailing;
  final VoidCallback? onPlayAll;
  final VoidCallback? onSave;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
      child: Row(
        children: [
          Icon(icon, color: SearchUi.titleAccent, size: 20),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              color: AppPalette.text,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (trailing != null && trailing!.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              trailing!,
              style: TextStyle(color: AppPalette.textSubtle, fontSize: 12),
            ),
          ],
          const Spacer(),
          if (onPlayAll != null)
            IconButton(
              tooltip: 'Tümünü çal',
              icon: Icon(Icons.play_circle_fill, color: SearchUi.titleAccent),
              onPressed: onPlayAll,
            ),
          if (onSave != null)
            IconButton(
              tooltip: 'Listeyi kaydet',
              icon: Icon(Icons.playlist_add, color: SearchUi.titleAccent),
              onPressed: onSave,
            ),
          if (onDownload != null)
            IconButton(
              tooltip: 'Tümünü indir',
              icon: Icon(Icons.download_for_offline,
                  color: SearchUi.titleAccent),
              onPressed: onDownload,
            ),
        ],
      ),
    );
  }
}

class SearchArtistCard extends StatelessWidget {
  const SearchArtistCard({
    super.key,
    required this.seed,
    required this.onTap,
  });

  final Track seed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 190,
      child: Material(
        color: AppPalette.card,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: AppPalette.cardRaised,
                  backgroundImage: CachedNetworkImageProvider(seed.thumb),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        seed.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Sanatçı',
                        style: TextStyle(
                          color: AppPalette.textSubtle,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: AppPalette.iconSubtle),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SearchTrackCard extends StatelessWidget {
  const SearchTrackCard({
    super.key,
    required this.track,
    required this.liked,
    required this.onAction,
  });

  final Track track;
  final bool liked;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onAction('play'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
        child: Row(
          children: [
            Stack(
              alignment: Alignment.bottomLeft,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(
                    imageUrl: track.thumb,
                    width: 60,
                    height: 60,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => Container(
                      color: AppPalette.card,
                      child: const Icon(Icons.music_note, size: 34),
                    ),
                  ),
                ),
                Container(
                  margin: const EdgeInsets.only(left: 2, bottom: 2),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xB3000000),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    SearchUi.durationLabel(track.duration),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppPalette.textSubtle,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (liked)
              Icon(Icons.favorite, size: 16, color: SearchUi.titleAccent),
            PopupMenuButton<String>(
              tooltip: 'Parça menüsü',
              icon: const Icon(Icons.more_vert),
              onSelected: onAction,
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'play', child: Text('Çal')),
                const PopupMenuItem(value: 'radio', child: Text('Radyo başlat')),
                PopupMenuItem(
                  value: 'like',
                  child: Text(liked ? 'Beğeniyi kaldır' : 'Beğen'),
                ),
                const PopupMenuItem(value: 'download', child: Text('İndir')),
                const PopupMenuItem(
                  value: 'artist',
                  child: Text('Sanatçıyı aç'),
                ),
                const PopupMenuItem(
                  value: 'playlist',
                  child: Text('Çalma listesine ekle'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class SearchNavBar extends StatelessWidget {
  const SearchNavBar({
    super.key,
    required this.selected,
    required this.onTap,
  });

  static const int home = 0;
  static const int search = 1;
  static const int library = 2;
  static const int settings = 3;

  final int selected;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppPalette.surface,
        border: Border(top: BorderSide(color: AppPalette.divider)),
      ),
      child: Row(
        children: [
          _item(Icons.home, 'Home', home),
          _item(Icons.search, 'Search', search),
          _item(Icons.library_music, 'Library', library),
          _item(Icons.settings_outlined, 'Settings', settings),
        ],
      ),
    );
  }

  Widget _item(IconData icon, String label, int value) {
    final active = value == selected;
    return Expanded(
      child: InkWell(
        onTap: () => onTap(value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (active)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 17,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: SearchUi.activeAccent,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child:
                      Icon(icon, size: 20, color: Colors.white),
                )
              else
                SizedBox(
                  height: 26,
                  child: Icon(icon, size: 20, color: AppPalette.iconSubtle),
                ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: active ? SearchUi.activeAccent : AppPalette.iconSubtle,
                  fontSize: 10,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
