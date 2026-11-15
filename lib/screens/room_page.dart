import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/theme_state.dart';
import '../ui/track_tile.dart';

/// Oda: kullanicinin kendi gorselini avatar olarak yukledigi kisisel alan.
/// Begenilen sarkilar tek kaydirilabilir listede gosterilir.
class RoomPage extends StatefulWidget {
  const RoomPage({super.key});

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  final ImagePicker _picker = ImagePicker();

  Future<void> _pickAvatar() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 768,
        maxHeight: 768,
        imageQuality: 85,
      );
      if (picked == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final target = File('${dir.path}/room_avatar.jpg');
      await File(picked.path).copy(target.path);
      await Library.instance.setAvatar(target.path);
    } catch (_) {
      // Secim iptal edilirse veya izin yoksa sessizce gec.
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = ThemeState.accent.value;
    final library = Library.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Oda')),
      body: ListenableBuilder(
        listenable: library,
        builder: (context, _) {
          final liked = library.liked;
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: liked.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return _RoomHeader(
                  avatarPath: library.avatarPath,
                  accent: accent,
                  likedCount: liked.length,
                  onPickAvatar: _pickAvatar,
                  onPlay: liked.isEmpty
                      ? null
                      : () => PlayerController.instance.playQueue(liked, 0),
                );
              }
              final Track t = liked[i - 1];
              return TrackTile(track: t, queue: liked, index: i - 1);
            },
          );
        },
      ),
    );
  }
}

class _RoomHeader extends StatelessWidget {
  const _RoomHeader({
    required this.avatarPath,
    required this.accent,
    required this.likedCount,
    required this.onPickAvatar,
    required this.onPlay,
  });

  final String? avatarPath;
  final Color accent;
  final int likedCount;
  final VoidCallback onPickAvatar;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    Widget avatar;
    if (avatarPath != null && File(avatarPath!).existsSync()) {
      avatar = Image.file(File(avatarPath!), fit: BoxFit.cover);
    } else {
      avatar = Icon(Icons.person, size: 64, color: accent);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        children: [
          GestureDetector(
            onTap: onPickAvatar,
            child: Stack(
              children: [
                Container(
                  width: 132,
                  height: 132,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF242424),
                    border: Border.all(color: accent, width: 2),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: avatar,
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.photo_camera,
                        size: 18, color: Colors.black),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Odam',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          Text(
            '$likedCount begenilen parca',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: onPlay,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Odayı çal'),
                style: FilledButton.styleFrom(backgroundColor: accent),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onPickAvatar,
                icon: const Icon(Icons.image_outlined),
                label: const Text('Avatar'),
              ),
            ],
          ),
          const Divider(height: 32),
        ],
      ),
    );
  }
}
