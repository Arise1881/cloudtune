import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../constants.dart';

/// Kapak görseli: önce yerel dosya, sonra ağ önbelleği, yoksa zengin yer tutucu.
/// iPhone tarzı: gradient kapak arkaplanı + müzik notu ikonu.
class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    this.url,
    this.localPath,
    this.size = 56,
    this.radius = 10,
  });

  final String? url;
  final String? localPath;
  final double size;
  final double radius;

  int get _decodeWidth => size > 256 ? (size * 1.2).toInt() : (size * 2).round();

  /// Renkli gradient yer tutucu: indirme yoksa / resim yoksa görünür.
  Widget _placeholder(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppColors.gradientTop, AppColors.cardLight],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Center(
          child: Icon(
            Icons.music_note,
            color: AppColors.accentBright.withValues(alpha: 0.9),
            size: size * 0.42,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (localPath != null && localPath!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(
          width: size,
          height: size,
          child: Image.file(
            File(localPath!),
            fit: BoxFit.cover,
            cacheWidth: _decodeWidth,
            errorBuilder: (_, _, _) => _placeholder(context),
          ),
        ),
      );
    }

    if (url != null && url!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(
          width: size,
          height: size,
          child: CachedNetworkImage(
            imageUrl: url!,
            fit: BoxFit.cover,
            memCacheWidth: _decodeWidth,
            httpHeaders: const {'User-Agent': 'Mozilla/5.0'},
            placeholder: (_, _) => _placeholder(context),
            errorWidget: (_, _, _) => _placeholder(context),
          ),
        ),
      );
    }

    return _placeholder(context);
  }
}
