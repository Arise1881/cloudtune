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
  });

  final String url;
  final double width;
  final double height;
  final double borderRadius;
  final BoxFit fit;
  final double iconSize;

  String? _fallbackUrl() {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.host == 'i.ytimg.com') {
      return uri.replace(host: 'img.youtube.com').toString();
    }
    if (uri.host == 'img.youtube.com') {
      return uri.replace(host: 'i.ytimg.com').toString();
    }
    return null;
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
    final fallback = _fallbackUrl();
    // Kapak dosyası küçük olsa da 320x180 tüm çözücü bellekte tutulur.
    // Görüntülenen boyuta göre decode ederek liste kaydırmada bellek ve
    // GPU yükünü azaltır; mobil veride ek indirme yapmaz.
    final ratio = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0);
    final cacheWidth = width.isFinite ? (width * ratio).round() : null;
    final cacheHeight = height.isFinite ? (height * ratio).round() : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: CachedNetworkImage(
        imageUrl: url,
        width: width,
        height: height,
        memCacheWidth: cacheWidth,
        memCacheHeight: cacheHeight,
        fit: fit,
        placeholder: (_, __) => _placeholder(),
        errorWidget: (_, __, ___) {
          if (fallback == null) return _error(Icons.music_note);
          return Image.network(
            fallback,
            width: width,
            height: height,
            cacheWidth: cacheWidth,
            cacheHeight: cacheHeight,
            fit: fit,
            errorBuilder: (_, __, ___) => _error(Icons.music_note),
          );
        },
      ),
    );
  }
}
