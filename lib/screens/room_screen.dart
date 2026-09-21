import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../services/player_service.dart';
import '../services/room_service.dart';

/// Oda için avatar seçenekleri (fotoğraf URL'si yerine hazır simgeler).
class RoomAvatarPreset {
  final String id;
  final IconData icon;
  final Color color;
  const RoomAvatarPreset(this.id, this.icon, this.color);
}

const List<RoomAvatarPreset> kRoomAvatarPresets = [
  RoomAvatarPreset('cat', Icons.pets, Color(0xFFE91E63)),
  RoomAvatarPreset('music', Icons.headphones, Color(0xFF1DB954)),
  RoomAvatarPreset('star', Icons.star, Color(0xFFFFC107)),
  RoomAvatarPreset('rocket', Icons.rocket_launch, Color(0xFF2196F3)),
  RoomAvatarPreset('bolt', Icons.bolt, Color(0xFFFF9800)),
  RoomAvatarPreset('fav', Icons.favorite, Color(0xFF9C27B0)),
  RoomAvatarPreset('casette', Icons.album, Color(0xFF607D8B)),
  RoomAvatarPreset('ghost', Icons.mood, Color(0xFF00BCD4)),
];

const String kRoomAvatarPrefix = 'preset_';

class RoomScreen extends StatefulWidget {
  const RoomScreen({super.key});

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  String _avatarId = kRoomAvatarPresets.first.id;
  String? _avatarPath;
  bool _createMode = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final room = RoomService.instance;
    _nameCtrl.text = room.displayName ?? '';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  String get _profilePhotoValue =>
      _avatarPath ?? '$kRoomAvatarPrefix$_avatarId';

  /// Galeriden avatar seçer; fotoğraf uygulama klasörüne kopyalanır ve oda
  /// adresi olarak yerel dosya yolu kullanılır (preset simgesi yerine).
  Future<void> _pickAvatar() async {
    if (kIsWeb) return; // Yerel dosya yolu yalnız mobil/masaüstü
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (picked == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final ext = picked.path.split('.').last.toLowerCase();
      final dest = File('${dir.path}/avatar.${ext == 'jpg' ? 'jpg' : 'png'}');
      await picked.saveTo(dest.path);
      if (!mounted) return;
      setState(() => _avatarPath = dest.path);
    } catch (_) {}
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    final room = RoomService.instance;
    final name = _nameCtrl.text.trim();
    final password = _passwordCtrl.text.trim();
    bool ok;
    if (_createMode) {
      ok = await room.createRoom(
        profilePhotoUrl: _profilePhotoValue,
        displayName: name,
        password: password,
      );
    } else {
      ok = await room.joinRoom(
        roomCode: _codeCtrl.text,
        password: password,
        profilePhotoUrl: _profilePhotoValue,
        displayName: name,
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(room.roomCode != null
              ? 'Oda kodu: ${room.roomCode}'
              : 'Odaya katılındı'),
          duration: const Duration(seconds: 2),
        ));
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Sunucuya bağlanılamadı. Lütfen tekrar deneyin.'),
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final room = context.watch<RoomService>();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        title: const Text('Sesli Oda',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: room.roomId == null ? _buildSetup(room) : _buildInRoom(room),
    );
  }

  Widget _buildSetup(RoomService room) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _createMode ? 'Oda kur' : 'Odaya katıl',
            style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          const Text(
            'Aynı oda kodundaki herkes şarkıyı senkron dinler. '
            'Odada herkes kontrol edebilir: çal/durdur, ileri, geri, aradeğiştir. '
            'Kulaklıkla dinleyen arkadaşın aynı şarkıyı aynı anda duyar.',
            style: TextStyle(color: AppColors.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 20),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Oda Kur')),
              ButtonSegment(value: false, label: Text('Katıl')),
            ],
            selected: {_createMode},
            onSelectionChanged: (s) => setState(() => _createMode = s.first),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _codeCtrl,
            enabled: !_createMode,
            style: const TextStyle(color: Colors.black87),
            textCapitalization: TextCapitalization.characters,
            maxLength: 5,
            decoration: const InputDecoration(
              labelText: 'Oda kodu',
              counterText: '',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(),
              hintText: 'ABC12',
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameCtrl,
            style: const TextStyle(color: Colors.black87),
            decoration: const InputDecoration(
              labelText: 'Görünen adın',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordCtrl,
            obscureText: true,
            style: const TextStyle(color: Colors.black87),
            decoration: const InputDecoration(
              labelText: 'Şifre (opsiyonel)',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 20),
          const Text('Avatarını seç',
              style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: kRoomAvatarPresets.map((a) {
              final selected = a.id == _avatarId && _avatarPath == null;
              return GestureDetector(
                onTap: () => setState(() {
                  _avatarPath = null;
                  _avatarId = a.id;
                }),
                child: CircleAvatar(
                  radius: 26,
                  backgroundColor: selected ? AppColors.accent : AppColors.cardLight,
                  child: Icon(a.icon,
                      color: selected ? AppColors.background : a.color),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          if (!kIsWeb)
            OutlinedButton.icon(
              onPressed: _pickAvatar,
              icon: Icon(_avatarPath == null
                  ? Icons.photo_library_outlined
                  : Icons.photo_library),
              label: Text(_avatarPath == null
                  ? 'Kendi fotoğrafını yükle'
                  : 'Fotoğraf seçildi — değiştir'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent,
                side: BorderSide(color: AppColors.accent),
              ),
            ),
          const SizedBox(height: 24),
          if (room.status == RoomStatus.connecting)
            const Center(child: CircularProgressIndicator())
          else
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
                onPressed: _submit,
                child: Text(
                    _createMode
                        ? 'Odayı Kur ve Başla'
                        : 'Odaya Katıl',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
          const SizedBox(height: 12),
          if (room.error != null)
            Text('Hata: ${room.error}',
                style: const TextStyle(color: AppColors.error, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildInRoom(RoomService room) {
    final player = context.watch<PlayerService>();
    final current = player.current;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Center(
          child: Column(
            children: [
              Icon(Icons.groups,
                  size: 56, color: room.role == RoomRole.owner
                      ? AppColors.accentBright
                      : AppColors.textSecondary),
              const SizedBox(height: 8),
              Text('Odadasın',
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                room.role == RoomRole.owner ? 'Sahip • sen kontrol ediyorsun'
                    : 'Üye • sen de kontrol edebilirsin',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () async {
                  await Clipboard.setData(
                      ClipboardData(text: room.roomCode ?? ''));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Oda kodu kopyalandı'),
                      duration: Duration(seconds: 1)));
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.accent, width: 2),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Kod: ${room.roomCode}',
                          style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2)),
                      const SizedBox(width: 8),
                      const Icon(Icons.copy, size: 18,
                          color: AppColors.textSecondary),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              const Text('Arkadaşın bu kodla katılabilir',
                  style: TextStyle(
                      color: AppColors.textTertiary, fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _sectionLabel('Odadaki kişiler (${room.memberCount})'),
        const SizedBox(height: 8),
        Row(
          children: [
            _memberAvatar(room.profilePhotoUrl ?? '', room.displayName ?? 'Sen'),
            ...room.members.values.map(
                (m) => _memberAvatar(m.photo, m.name)),
          ],
        ),
        const SizedBox(height: 24),
        _sectionLabel('Şimdi çalıyor'),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.music_note,
                  size: 28, color: player.isPlaying
                      ? AppColors.accentBright
                      : AppColors.textTertiary),
              const SizedBox(width: 12),
              Expanded(
                child: current == null
                    ? const Text('Henüz şarkı yok',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 14))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(current.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w700)),
                          Text(current.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 13)),
                        ],
                      ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (current == null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.cardLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline,
                    size: 18, color: AppColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Şarkı ara (Arama sekmesi) ve çaldığında odadaki herkes senkron dinlesin.',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _roomControl(Icons.skip_previous, () {
              room.sendCommand('prev');
            }),
            const SizedBox(width: 16),
            _roomControl(player.isPlaying ? Icons.pause : Icons.play_arrow,
                () {
              room.sendCommand('toggle');
            }, accent: true),
            const SizedBox(width: 16),
            _roomControl(Icons.skip_next, () {
              room.sendCommand('next');
            }),
          ],
        ),
        const SizedBox(height: 28),
        OutlinedButton.icon(
          onPressed: () => room.leaveRoom(),
          icon: const Icon(Icons.logout),
          label: const Text('Odadan Ayrıl'),
          style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.error,
              side: const BorderSide(color: AppColors.error)),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _sectionLabel(String text) => Text(text,
      style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w700));

  Widget _memberAvatar(String photo, String name) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Tooltip(
        message: name,
        child: _AvatarTile(photo: photo, name: name),
      ),
    );
  }

  Widget _roomControl(IconData icon, VoidCallback onTap,
      {bool accent = false}) {
    return Container(
      decoration: BoxDecoration(
        color: accent ? AppColors.accent : AppColors.card,
        shape: BoxShape.circle,
      ),
      child: IconButton(
        iconSize: accent ? 30 : 26,
        color: accent ? Colors.white : AppColors.textPrimary,
        onPressed: onTap,
        icon: Icon(icon),
      ),
    );
  }
}

Widget roomAvatarWidget(String? photo,
    {double radius = 24, Color fallback = AppColors.cardLight}) {
  final value = photo ?? '';
  if (value.startsWith(kRoomAvatarPrefix)) {
    final id = value.substring(kRoomAvatarPrefix.length);
    final preset = kRoomAvatarPresets.where((p) => p.id == id).firstOrNull;
    return CircleAvatar(
      radius: radius,
      backgroundColor: preset?.color ?? fallback,
      child: Icon(preset?.icon ?? Icons.person,
          color: Colors.white, size: radius),
    );
  }
  if (value.isNotEmpty) {
    // Yerel dosya yolu avatar fotoğrafı; aksi halde URL.
    final isFile = value.startsWith('/') || value.startsWith('file://');
    final ImageProvider<Object> provider =
        isFile ? FileImage(File(value)) : NetworkImage(value);
    return CircleAvatar(
      radius: radius,
      backgroundColor: fallback,
      foregroundImage: provider,
      child: const Icon(Icons.person, color: AppColors.textSecondary),
    );
  }
  return CircleAvatar(
    radius: radius,
    backgroundColor: fallback,
    child: const Icon(Icons.person, color: AppColors.textSecondary),
  );
}

class _AvatarTile extends StatelessWidget {
  const _AvatarTile({required this.photo, required this.name});
  final String photo;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        roomAvatarWidget(photo),
        const SizedBox(height: 4),
        SizedBox(
          width: 56,
          child: Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 11)),
        ),
      ],
    );
  }
}