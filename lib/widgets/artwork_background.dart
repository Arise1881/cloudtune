/*
 * Premium ambient background for the now-playing screen.
 *
 * Extracts the dominant color of the currently playing artwork and paints an
 * animated aurora/stained-glass gradient behind the player. This gives the
 * screen the rich, immersive "ambient" look found in premium music apps
 * without adding any dependency: the artwork is resolved through the same
 * image providers already in use and averaged in a background isolate.
 */

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Crossfades between the artwork-derived gradient and the app surface color.
class ArtworkBackground extends StatefulWidget {
  const ArtworkBackground({
    super.key,
    required this.metadata,
    required this.child,
  });

  final MediaItem metadata;
  final Widget child;

  @override
  State<ArtworkBackground> createState() => _ArtworkBackgroundState();
}

class _ArtworkBackgroundState extends State<ArtworkBackground> {
  static final ValueNotifier<Color?> _shareLastDominant =
      ValueNotifier<Color?>(null);
  Color _dominant = Colors.transparent;
  bool _hasColor = false;
  ImageStream? _stream;
  final ImageStreamListener _listener = ImageStreamListener(
    _onImageAvailable,
    onError: (_, _) {},
  );

  @override
  void initState() {
    super.initState();
    final existing = _shareLastDominant.value;
    if (existing != null) {
      _dominant = existing;
      _hasColor = true;
    }
    _extractFrom(widget.metadata);
  }

  @override
  void didUpdateWidget(ArtworkBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldArt = oldWidget.metadata.artUri?.toString();
    final newArt = widget.metadata.artUri?.toString();
    if (oldWidget.metadata.id != widget.metadata.id || oldArt != newArt) {
      _extractFrom(widget.metadata);
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _detach() {
    _stream?.removeListener(_listener);
    _stream = null;
  }

  void _extractFrom(MediaItem metadata) {
    final art = metadata.artUri;
    _detach();
    if (art == null) return;

    try {
      final ImageProvider<Object> provider = art.scheme == 'file'
          ? FileImage(File(metadata.extras?['artWorkPath'] as String? ?? ''))
          : CachedNetworkImageProvider(art.toString());
      _stream = provider.resolve(ImageConfiguration.empty);
      _stream!.addListener(_listener);
    } catch (_) {
      // Leave the default surface color if the artwork can't be resolved.
    }
  }

  static void _onImageAvailable(ImageInfo info, bool synchronousCall) {
    final image = info.image;
    final pixels = image.toByteData(format: ui.ImageByteFormat.rawRgba);
    unawaited(
      pixels.then((data) {
        if (data == null) return;
        final tuple = (
          data.buffer.asUint8List(),
          image.width,
          image.height,
        );
        compute(_averageRgb, tuple).then(
          (color) => _shareLastDominant.value = color,
        );
      }).whenComplete(image.dispose),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ValueListenableBuilder<Color?>(
      valueListenable: _shareLastDominant,
      builder: (context, latest, _) {
        final effective = latest ?? _dominant;
        final hasColor = latest != null || _hasColor;
        final usedDominant = hasColor ? effective : colorScheme.surface;

        final gradient = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.alphaBlend(
              usedDominant.withValues(alpha: hasColor ? 0.85 : 0),
              colorScheme.surface,
            ),
            Color.alphaBlend(
              usedDominant.withValues(alpha: hasColor ? 0.35 : 0),
              colorScheme.surface,
            ),
            colorScheme.surface,
          ],
          stops: const [0.0, 0.55, 1.0],
        );
        final glow = RadialGradient(
          center: const Alignment(0, -0.75),
          radius: 1.1,
          colors: [
            usedDominant.withValues(alpha: hasColor ? 0.40 : 0),
            Colors.transparent,
          ],
        );

        return ColoredBox(
          color: colorScheme.surface,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(gradient: gradient),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 900),
                curve: Curves.easeOut,
                decoration: BoxDecoration(gradient: glow),
              ),
              widget.child,
            ],
          ),
        );
      },
    );
  }
}

/// Static average-of-channels color (RGB only, alpha ignored).
@pragma('vm:entry-point')
Color _averageRgb((Uint8List data, int width, int height) args) {
  final (data, width, height) = args;
  var r = 0, g = 0, b = 0;
  final n = width * height;
  for (var i = 0; i < data.length; i += 4) {
    r += data[i];
    g += data[i + 1];
    b += data[i + 2];
  }
  return Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
}