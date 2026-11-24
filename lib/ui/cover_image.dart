import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
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

  /// Windows'ta göreli/proxy kapak URL'leri yüklenmiyor. Parça kimliği
  /// `/vi/<id>/` yolundan çıkarılıp canonical YouTube CDN'ine çevrilir.
  String? _youtubeIdFromPath() {
    final segments = Uri.tryParse(url)?.pathSegments ?? const <String>[];
    final index = segments.indexOf('vi');
    if (index < 0 || index + 1 >= segments.length) return null;
    final id = segments[index + 1];
    return id.isEmpty ? null : id;
  }

  String _resolvedUrl() {
    if (defaultTargetPlatform != TargetPlatform.windows) return url;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      final id = _youtubeIdFromPath();
      return id == null ? url : 'https://i.ytimg.com/vi/$id/mqdefault.jpg';
    }
    if (uri.scheme == 'file' || uri.scheme == 'data') return url;
    final host = uri.host.toLowerCase();
    if (!host.endsWith('ytimg.com') && !host.endsWith('youtube.com')) {
      final id = _youtubeIdFromPath();
      return id == null ? url : 'https://i.ytimg.com/vi/$id/mqdefault.jpg';
    }
    return url;
  }

  String? _fallbackUrl(String source) {
    final uri = Uri.tryParse(source);
    if (uri == null) return null;
    if (uri.host == 'i.ytimg.com') {
      return uri.replace(host: 'img.youtube.com').toString();
    }
    if (uri.host == 'img.youtube.com') {
      return uri.replace(host: 'i.ytimg.com').toString();
    }
    return null;
  }

  Map<String, String>? get _headers =>
      defaultTargetPlatform == TargetPlatform.windows
          ? const <String, String>{
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) CloudTune/3.0',
              'Referer': 'https://www.youtube.com/',
            }
          : null;

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
    final resolved = _resolvedUrl();
    final fallback = _fallbackUrl(resolved);
    final headers = _headers;
    // Kapak dosyası küçük olsa da 320x180 tüm çözücü bellekte tutulur.
    // Görüntülenen boyuta göre decode ederek liste kaydırmada bellek ve
    // GPU yükünü azaltır; mobil veride ek indirme yapmaz.
    final ratio = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0);
    final cacheWidth = width.isFinite ? (width * ratio).round() : null;
    final cacheHeight = height.isFinite ? (height * ratio).round() : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: CachedNetworkImage(
        imageUrl: resolved,
        httpHeaders: headers,
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
            headers: headers ?? const <String, String>{},
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
