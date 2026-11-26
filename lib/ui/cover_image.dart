import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// YouTube kapakları için iki CDN yolu dener. `i.ytimg.com` bazı
/// ağlarda/Google TV DNS'inde çözümlenmediğinde `img.youtube.com` devreye girer.
/// İkisi de başarısızsa sade bir müzik simgesi gösterilir.
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    this.borderRadius = 8,
    this.fit = BoxFit.cover,
    this.iconSize = 34,
    this.cacheKey,
  });

  /// Kapak yenileme nesli. Pull-to-refresh sonrası aynı URL yeniden indirilir;
  /// aksi halde CachedNetworkImage eski dosyayı sonsuza kadar gösterir.
  static int _epoch = 0;

  static void refresh() => _epoch++;

  final String url;
  final double width;
  final double height;
  final double borderRadius;
  final BoxFit fit;
  final double iconSize;
  final String? cacheKey;

  List<String> _candidateUrls() {
    var primary = url.trim();
    if (primary.isEmpty) return const [];
    if (primary.startsWith('//')) primary = 'https:$primary';
    if (primary.startsWith('/')) {
      primary = primary.startsWith('/vi/')
          ? 'https://i.ytimg.com$primary'
          : 'https://www.youtube.com$primary';
    }
    final uri = Uri.tryParse(primary);
    final out = <String>[];
    void add(String? u) {
      if (u == null) return;
      final v = u.trim();
      if (v.isEmpty || out.contains(v)) return;
      out.add(v);
    }

    add(primary);

    // YouTube vi kapaklarında büyük görsel isteyen yerler için kalite zinciri.
    final isYtThumb = uri != null &&
        (uri.host.endsWith('ytimg.com') || uri.host.endsWith('youtube.com')) &&
        uri.pathSegments.length >= 3 &&
        uri.pathSegments[uri.pathSegments.length - 3] == 'vi';
    if (isYtThumb) {
      final segs = uri.pathSegments;
      final last = segs.last;
      final highQualityView = !width.isFinite || width >= 180 || height >= 180;
      final variants = highQualityView
          ? const [
              'maxresdefault.jpg',
              'sddefault.jpg',
              'hq720.jpg',
              'hqdefault.jpg',
              'mqdefault.jpg',
            ]
          : const ['mqdefault.jpg', 'hqdefault.jpg'];
      for (final v in variants) {
        final candidate = uri.replace(pathSegments: [...segs.sublist(0, segs.length - 1), v]).toString();
        add(candidate);
        // CDN host fallback
        if (uri.host == 'i.ytimg.com') {
          add(Uri.parse(candidate).replace(host: 'img.youtube.com').toString());
        } else if (uri.host == 'img.youtube.com') {
          add(Uri.parse(candidate).replace(host: 'i.ytimg.com').toString());
        }
      }
      // Keep original last if different (e.g. webp/custom)
      if (!variants.contains(last)) {
        add(primary);
      }
    } else {
      // Non-YT: just host fallback
      if (uri?.host == 'i.ytimg.com') {
        add(uri!.replace(host: 'img.youtube.com').toString());
      } else if (uri?.host == 'img.youtube.com') {
        add(uri!.replace(host: 'i.ytimg.com').toString());
      }
    }
    return out;
  }

  Widget _placeholder() => Container(
        width: width,
        height: height,
        color: const Color(0xFF232323),
      );

  Widget _error(IconData icon) => SizedBox(
        width: width,
        height: height,
        child: Icon(icon, size: iconSize, color: Colors.white54),
      );

  @override
  Widget build(BuildContext context) {
    final candidates = _candidateUrls();
    if (candidates.isEmpty) return _error(Icons.music_note);
    final ratio = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0);
    final cacheWidth = width.isFinite ? (width * ratio).round() : null;
    final cacheHeight = height.isFinite ? (height * ratio).round() : null;

    Widget buildAt(int i) {
      final u = candidates[i];
      final key = cacheKey == null ? '$u#$_epoch' : '$cacheKey#$u#$_epoch';
      return CachedNetworkImage(
        imageUrl: u,
        cacheKey: key,
        width: width,
        height: height,
        memCacheWidth: cacheWidth,
        memCacheHeight: cacheHeight,
        fit: fit,
        placeholder: (_, __) => _placeholder(),
        errorWidget: (_, __, ___) =>
            i + 1 < candidates.length ? buildAt(i + 1) : _error(Icons.music_note),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: buildAt(0),
    );
  }
}
