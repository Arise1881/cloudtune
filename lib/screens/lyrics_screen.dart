import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../models/song.dart';
import '../services/music_service.dart';
import '../services/player_service.dart';
import '../services/lyrics_parser.dart';

/// YouTube Music benzeri eş zamanlı şarkı sözü ekranı.
class LyricsScreen extends StatefulWidget {
  const LyricsScreen({super.key, required this.song, this.player});

  final Song song;
  final PlayerService? player;

  @override
  State<LyricsScreen> createState() => _LyricsScreenState();
}

class _LyricsScreenState extends State<LyricsScreen> {
  late Future<String> _future;
  late PlayerService _player;
  Timer? _positionTimer;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player = widget.player ?? context.read<PlayerService>();
    _future = MusicService.instance.fetchLyrics(widget.song);
    _startPositionListener();
  }

  void _startPositionListener() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (_player.player.playing && _player.current?.id == widget.song.id) {
        setState(() => _position = _player.player.position);
      }
    });
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        title: Column(
          children: [
            Text(widget.song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            Text(widget.song.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ],
        ),
      ),
      body: FutureBuilder<String>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            );
          }
          if (snap.hasError || snap.data == null || snap.data!.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lyrics_outlined,
                      size: 48, color: AppColors.textSecondary),
                  const SizedBox(height: 12),
                  const Text('Şarkı sözü bulunamadı',
                      style: TextStyle(color: AppColors.textSecondary)),
                  const SizedBox(height: 8),
                  const Text('Bu şarkı için söz verisi alınamadı.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          height: 1.5)),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: () =>
                        setState(() => _future = MusicService.instance
                            .fetchLyrics(widget.song)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.accent,
                      side: const BorderSide(color: AppColors.accent),
                    ),
                    child: const Text('Tekrar dene'),
                  ),
                ],
              ),
            );
          }
          // LRC formatını parse et ve senkronize widget ile göster
          final lyrics = LrcParser.parse(snap.data!);
          return StreamBuilder<Duration>(
            stream: _player.player.positionStream,
            initialData: _position,
            builder: (context, snapshot) {
              final position = snapshot.data ?? _position;
              return SyncedLyricsWidget(
                lines: lyrics,
                position: position,
              );
            },
          );
        },
      ),
    );
  }
}
