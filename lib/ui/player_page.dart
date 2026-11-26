import 'package:flutter/material.dart';

import 'cover_image.dart';

import '../core/app_palette.dart';
import '../core/download_service.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/settings_service.dart';
import '../core/theme_state.dart';
import '../screens/artist_page.dart';

String _fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
}

const Map<String, String> _qualityLabels = {
  'low': 'DÜŞÜK',
  'medium': 'ORTA',
  'high': 'YÜKSEK',
  'lossless': 'KAYIPSIZ',
};

// Yeni controller API'leri henüz yoksa derleme bozulmasın: dynamic okuma +
// mevcut API'lere düşüş. API gelince aynı kod yeni alanları kullanır.
bool _shuffleEnabled(Object player) {
  try {
    final value = (player as dynamic).shuffleEnabled;
    if (value is bool) return value;
  } catch (_) {}
  try {
    final value = (player as dynamic).shuffleMode;
    if (value is bool) return value;
  } catch (_) {}
  return false;
}

void _setShuffleEnabled(Object player, bool enabled) {
  try {
    final result = (player as dynamic).setShuffleEnabled(enabled);
    if (result is Future) result.catchError((_) {});
    return;
  } catch (_) {}
  try {
    if (_shuffleEnabled(player) != enabled) {
      (player as dynamic).toggleShuffle();
    }
  } catch (_) {}
}

String _repeatMode(Object player) {
  try {
    final value = (player as dynamic).repeatMode;
    final text = value?.toString().toLowerCase() ?? '';
    if (text.contains('one')) return 'one';
    if (text.contains('all')) return 'all';
  } catch (_) {}
  return 'off';
}

void _cycleRepeat(Object player, BuildContext context) {
  try {
    final result = (player as dynamic).cycleRepeatMode();
    if (result is Future) result.catchError((_) {});
    return;
  } catch (_) {}
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.showSnackBar(
    const SnackBar(content: Text('Tekrar ayarı bu sürümde kullanılamıyor.')),
  );
}

bool _radioActive(Object player) {
  try {
    final value = (player as dynamic).radioMode;
    if (value is bool) return value;
  } catch (_) {}
  return false;
}

String _normalizeQuality(String raw) {
  final q = raw.toLowerCase().replaceAll(' ', '').replaceAll('_', '');
  if (q.contains('lossless') || q.contains('veryhigh')) return 'lossless';
  if (q.contains('medium')) return 'medium';
  if (q.contains('low')) return 'low';
  return 'high';
}

String _qualityOf(Object player) {
  try {
    final value = (player as dynamic).quality;
    if (value != null) return _normalizeQuality(value.toString());
  } catch (_) {}
  try {
    return _normalizeQuality(SettingsService.instance.audioQuality);
  } catch (_) {
    return 'high';
  }
}

Future<void> _setQuality(Object player, String value) async {
  try {
    final result = (player as dynamic).setQuality(value);
    if (result is Future) await result;
    return;
  } catch (_) {}
  // Ayarlar ekranındaki mevcut anahtar 'veryhigh' kullanıyor.
  try {
    await SettingsService.instance
        .setAudioQuality(value == 'lossless' ? 'veryhigh' : value);
  } catch (_) {}
}

RelativeRect _menuRect(BuildContext context) {
  final box = context.findRenderObject() as RenderBox;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return RelativeRect.fill;
  return RelativeRect.fromRect(
    Rect.fromPoints(
      box.localToGlobal(Offset.zero, ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
    ),
    Offset.zero & overlay.size,
  );
}

Future<void> _showQualityMenu(BuildContext context, Object player) async {
  final current = _qualityOf(player);
  final selected = await showMenu<String>(
    context: context,
    position: _menuRect(context),
    items: [
      for (final entry in _qualityLabels.entries)
        PopupMenuItem<String>(
          value: entry.key,
          child: Row(
            children: [
              Icon(
                entry.key == current ? Icons.check : Icons.circle,
                size: 14,
              ),
              const SizedBox(width: 10),
              Text(entry.value),
            ],
          ),
        ),
    ],
  );
  if (selected == null || !context.mounted) return;
  await _setQuality(player, selected);
}

/// Full-screen playback view.
class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});

  void _openArtist(BuildContext context, Track track) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistPage(
          name: track.artist,
          channelId: track.artistId,
          seedTrack: track,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = PlayerController.instance;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Şimdi çalıyor'),
        centerTitle: true,
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([player, SettingsService.instance]),
        builder: (context, _) {
          final track = player.current;
          if (track == null) {
            return const Center(child: Text('Çalan şarkı yok.'));
          }

          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: CoverImage(
                        url: track.thumb,
                        width: double.infinity,
                        height: double.infinity,
                        borderRadius: 12,
                        fit: BoxFit.cover,
                        iconSize: 96,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    track.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: GestureDetector(
                    onTap: () => _openArtist(context, track),
                    child: Text(
                      track.artist,
                      style: TextStyle(
                        color: ThemeState.value.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (_radioActive(player))
                      _StatusBadge(
                        label: 'RADYO',
                        icon: Icons.radio,
                        color: ThemeState.value,
                        tooltip: 'Radyo modu açık',
                      ),
                    if (_radioActive(player)) const SizedBox(width: 8),
                    _QualityBadge(player: player),
                  ],
                ),
                const SizedBox(height: 12),
                if (player.error != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border:
                          Border.all(color: Colors.red.withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline,
                            color: Colors.redAccent),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            player.errorMessage ??
                                'Bu parça oynatılamadı. Başka parçaya geçilmedi.',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        TextButton(
                          onPressed: player.retry,
                          child: const Text('Tekrar dene'),
                        ),
                      ],
                    ),
                  ),
                _SeekBar(track: track),
                _Controls(track: track),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SeekBar extends StatelessWidget {
  const _SeekBar({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final player = PlayerController.instance;

    return StreamBuilder<Duration?>(
      stream: player.durationStream,
      builder: (context, duration) {
        final total = duration.data ?? track.duration ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: player.positionStream,
          builder: (context, position) {
            final pos = position.data ?? Duration.zero;
            final max = total.inMilliseconds.toDouble();
            final value =
                pos.inMilliseconds.toDouble().clamp(0.0, max > 0 ? max : 1.0);

            return Column(
              children: [
                Slider(
                  value: value,
                  max: max > 0 ? max : 1.0,
                  onChanged: max > 0
                      ? (v) => player.seek(Duration(milliseconds: v.round()))
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmt(pos)),
                      Text(_fmt(total)),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final player = PlayerController.instance;

    final shuffleOn = _shuffleEnabled(player);
    final repeatMode = _repeatMode(player);
    final active = ThemeState.value;
    final inactive = AppPalette.textSubtle;
    const compact = BoxConstraints.tightFor(width: 42, height: 42);

    // Flutter Material ikon setinde `repeat_off` yok. Kapalı durumda aynı
    // `repeat` glifini soluk renkte gösteriyoruz; `repeat_one` ayrı glif.
    final repeatIcon = switch (repeatMode) {
      'one' => Icon(Icons.repeat_one, color: active),
      'all' => Icon(Icons.repeat, color: active),
      _ => Icon(Icons.repeat, color: inactive),
    };
    final repeatTooltip = switch (repeatMode) {
      'one' => 'Tekrar: bir parça',
      'all' => 'Tekrar: tümü',
      _ => 'Tekrar: kapalı',
    };

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ListenableBuilder(
          listenable: Library.instance,
          builder: (context, _) {
            final liked = Library.instance.isLiked(track.id);
            return IconButton(
              tooltip: liked ? 'Beğeniyi kaldır' : 'Beğen',
              icon: Icon(
                liked ? Icons.favorite : Icons.favorite_border,
                color: liked ? active : null,
              ),
              onPressed: () => Library.instance.toggleLike(track),
            );
          },
        ),
        IconButton(
          tooltip: 'Önceki parça',
          iconSize: 36,
          constraints: compact,
          icon: const Icon(Icons.skip_previous),
          onPressed: player.previous,
        ),
        IconButton(
          tooltip: shuffleOn ? 'Karışık çalma açık' : 'Karışık çalma kapalı',
          iconSize: 20,
          constraints: compact,
          icon: Icon(
            Icons.shuffle,
            color: shuffleOn ? active : inactive,
          ),
          onPressed: () => _setShuffleEnabled(player, !shuffleOn),
        ),
        player.loading
            ? const SizedBox(
                width: 64,
                height: 64,
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              )
            : IconButton.filled(
                tooltip: player.playing ? 'Duraklat' : 'Oynat',
                iconSize: 48,
                // Broadcast stream ilk durumu kaçırabiliyor;
                // _broadcast() zaten notifyListeners() çağırır.
                icon: Icon(player.playing ? Icons.pause : Icons.play_arrow),
                onPressed: player.toggle,
              ),
        IconButton(
          tooltip: 'Sonraki parça',
          iconSize: 36,
          constraints: compact,
          icon: const Icon(Icons.skip_next),
          onPressed: player.hasNext ? player.next : null,
        ),
        _DownloadButton(track: track),
        IconButton(
          tooltip: repeatTooltip,
          iconSize: 20,
          constraints: compact,
          icon: repeatIcon,
          onPressed: () => _cycleRepeat(player, context),
        ),
      ],
    );
  }
}

class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final service = DownloadService.instance;

    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        if (service.isDownloading(track.id)) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                value: service.progressOf(track.id),
                strokeWidth: 2,
              ),
            ),
          );
        }

        final saved = service.savedPathOf(track.id) != null;
        return IconButton(
          tooltip: saved ? 'İndirildi' : 'İndir',
          icon: Icon(saved ? Icons.download_done : Icons.download_outlined),
          onPressed: () async {
            final messenger = ScaffoldMessenger.maybeOf(context);
            final path = await service.download(track);
            if (!context.mounted) return;
            messenger?.showSnackBar(
              SnackBar(
                content: Text(
                  path != null
                      ? 'Cihaza kaydedildi.'
                      : 'İndirme başarısız. Onarım botu yeniden deneyecek.',
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.label,
    required this.color,
    required this.icon,
    this.tooltip,
    this.onTap,
  });

  final String label;
  final Color color;
  final IconData icon;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );

    final semantic = Semantics(
      button: onTap != null,
      label: tooltip ?? label,
      child: badge,
    );
    if (onTap == null) return semantic;
    return Tooltip(
      message: tooltip ?? label,
      child: GestureDetector(onTap: onTap, child: semantic),
    );
  }
}

class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.player});

  final Object player;

  @override
  Widget build(BuildContext context) {
    final quality = _qualityOf(player);
    final label = _qualityLabels[quality] ?? quality.toUpperCase();
    return _StatusBadge(
      label: label,
      icon: Icons.high_quality_outlined,
      color: ThemeState.value,
      tooltip: 'Ses kalitesi: $label · değiştirmek için dokun',
      onTap: () => _showQualityMenu(context, player),
    );
  }
}
