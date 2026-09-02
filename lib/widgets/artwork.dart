import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../constants.dart';

/// Kapak görseli: önce yerel dosya, sonra ağ önbelleği, yoksa yer tutucu.
/// Destekler: yerel dosya, ağ resmi (GIF animasyonu desteklenmez, ilk kare gösterilir).
class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    this.url,
    this.localPath,
    this.size = 56,
    this.radius = 6,
  });

  final String? url;
  final String? localPath;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    if (localPath != null && localPath!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(width: size, height: size, child: Image.file(
          File(localPath!),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _placeholder(),
        )),
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
            httpHeaders: const {'User-Agent': 'Mozilla/5.0'},
            placeholder: (_, _) => _placeholder(),
            errorWidget: (_, _, _) => _placeholder(),
          ),
        ),
      );
    }

    return _placeholder();
  }

  Widget _placeholder() => Container(
        color: AppColors.card,
        child: Icon(Icons.music_note, color: AppColors.textSecondary, size: size * 0.4),
      );
}