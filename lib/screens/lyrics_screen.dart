import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../models/song.dart';
import '../services/music_service.dart';
import '../services/player_service.dart';

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
                  Text(_maybeRetry(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
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
          final lyrics = snap.data!;
          final lines = lyrics.split('\n').where((l) => l.trim().isNotEmpty).toList();
          return Scrollbar(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(28, 12, 28, 40),
              itemCount: lines.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  children: [
                    Text(
                      _getLineTime(i),
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 10),
                    ),
                    const Expanded(child: Text('')),
                    Text(
                      lines[i],
                      style: TextStyle(
                        color: _isCurrentLine(i) ? AppColors.accentBright : AppColors.textPrimary,
                        fontSize: 17,
                        height: 1.5,
                        fontWeight: FontWeight.w500,
                        decoration: _isCurrentLine(i) ? TextDecoration.underline : TextDecoration.none,
                        decorationColor: AppColors.accentBright,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  bool _isCurrentLine(int lineIndex) {
    if (_position == Duration.zero) return false;
    // Her söz satırı yaklaşık 4-6 saniye sürmeyi hedefliyor
    final lineDuration = Duration(seconds: 5);
    final lineStart = lineDuration * lineIndex;
    final lineEnd = lineStart + lineDuration;
    return _position >= lineStart && _position < lineEnd;
  }

  String _getLineTime(int lineIndex) {
    final minutes = lineIndex ~/ 12;
    final seconds = (lineIndex % 12 * 5).remainder(60);
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String _maybeRetry() => widget.song.title.isEmpty
      ? 'Bu şarkı için söz verisi alınamadı.'
      : 'Bu şarkı için söz verisi alınamadı. İnternet bağlantını kontrol et.';
}
