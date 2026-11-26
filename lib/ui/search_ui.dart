import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/app_palette.dart';
import '../core/models.dart';
import '../core/theme_state.dart';
import '../core/youtube_service.dart';
import 'cover_image.dart';

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

  /// Arama sonuçlarını korur, ek parçaları yalnızca sona ekler.
  /// Böylece aratılan şarkı listeden kaybolmaz; yenilemeyle gelen ilgili
  /// parçalar aynı listede yeni satırlar olarak görünür.
  static List<Track> mergedResults(List<Track> results, List<Track> extra) {
    final seen = <String>{};
    final merged = <Track>[];
    for (final track in [...results, ...extra]) {
      if (track.id.isEmpty) {
        merged.add(track);
        continue;
      }
      if (seen.add(track.id)) merged.add(track);
    }
    return merged;
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
              icon:
                  Icon(Icons.download_for_offline, color: SearchUi.titleAccent),
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
    // Parmak yüzeyden kalkmadan önce adres çözümünü başlat; dokunma→ses
    // gecikmesindeki en büyük ağ turu bu şekilde gizlenir.
    return InkWell(
      onTapDown: (_) => unawaited(YoutubeService.instance.prefetch(track.id)),
      onTap: () => onAction('play'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
        child: Row(
          children: [
            Stack(
              alignment: Alignment.bottomLeft,
              children: [
                CoverImage(
                  url: track.thumb,
                  width: 60,
                  height: 60,
                  iconSize: 34,
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
                const PopupMenuItem(
                    value: 'radio', child: Text('Radyo başlat')),
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
    // SafArea yalnızca altı korur: üstteki içerik zaten kendi SafeArea'sında.
    // Gesture navigation kullanan cihazlarda viewPadding.bottom=0 olur,
    // 3 tuşlu cihazlarda ise ikonlar sistem çubuğunun üstüne taşmaz.
    return SafeArea(
      top: false,
      bottom: true,
      maintainBottomViewPadding: true,
      child: Container(
        decoration: BoxDecoration(
          color: AppPalette.surface,
          border: Border(top: BorderSide(color: AppPalette.divider)),
        ),
        child: Row(
          children: [
            _item(context, Icons.home, 'Home', home),
            _item(context, Icons.search, 'Search', search),
            _item(context, Icons.library_music, 'Library', library),
            _item(context, Icons.settings_outlined, 'Settings', settings),
          ],
        ),
      ),
    );
  }

  Widget _item(BuildContext context, IconData icon, String label, int value) {
    final active = value == selected;
    // Dar ekranlarda ikon/yazı küçülür; geniş tabletlerde büyür.
    final mq = MediaQuery.of(context);
    final width = mq.size.width;
    final bottomInset = mq.viewPadding.bottom;
    final thickNav = bottomInset >= 24;
    final compact = width < 360;
    final wide = width >= 600;
    final iconSize = compact ? 18.0 : (wide ? 22.0 : 20.0);
    final labelSize = compact ? 9.0 : (wide ? 11.0 : 10.0);
    final pillPadding = compact ? 12.0 : (wide ? 20.0 : 17.0);
    final verticalPad = thickNav ? (compact ? 3.0 : 4.0) : (compact ? 5.0 : 7.0);
    return Expanded(
      child: InkWell(
        onTap: () => onTap(value),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: verticalPad),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (active)
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: pillPadding,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: SearchUi.activeAccent,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(icon, size: iconSize, color: Colors.white),
                )
              else
                SizedBox(
                  height: iconSize + 6,
                  child:
                      Icon(icon, size: iconSize, color: AppPalette.iconSubtle),
                ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: active ? SearchUi.activeAccent : AppPalette.iconSubtle,
                  fontSize: labelSize,
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
