import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/room_service.dart';
import '../core/theme_state.dart';

/// Yerel oda yönetimi ve kişisel kitaplık.
///
/// Senkronizasyon için harici sunucu gerekir; bu sayfa yalnızca cihaz
/// üzerindeki oda, avatar, beğeni ve geçmiş verilerini gösterir.
class RoomPage extends StatefulWidget {
  const RoomPage({super.key});

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage>
    with SingleTickerProviderStateMixin {
  static const _displayNameKey = 'room_display_name';

  final ImagePicker _picker = ImagePicker();
  late final TabController _tabs = TabController(length: 2, vsync: this);

  final TextEditingController _displayName = TextEditingController();
  final TextEditingController _roomName = TextEditingController();
  final TextEditingController _password = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(RoomService.init());
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString(_displayNameKey) ?? '';
      if (mounted && saved.isNotEmpty) _displayName.text = saved;
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _displayName.dispose();
    _roomName.dispose();
    _password.dispose();
    super.dispose();
  }

  TextStyle? get _sectionTitle => Theme.of(context)
      .textTheme
      .titleMedium
      ?.copyWith(fontWeight: FontWeight.w700);

  ImageProvider? get _avatarImage {
    final path = Library.instance.avatarPath;
    if (path == null || path.isEmpty || !File(path).existsSync()) return null;
    return FileImage(File(path));
  }

  Future<void> _saveDisplayName(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_displayNameKey, value);
  }

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

      if (RoomService.instance.inRoom) {
        final bytes = await target.readAsBytes();
        final dataUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';
        await RoomService.instance.uploadAvatar(dataUrl);
      }
    } catch (_) {
      // Seçim iptal edildi ya da galeri izni verilmedi.
    }
  }

  Future<void> _createRoom() async {
    final name = _displayName.text.trim();
    if (name.isNotEmpty) await _saveDisplayName(name);
    final created = await RoomService.instance.create(
      name: _roomName.text.trim(),
      password: _password.text,
      displayName: name,
    );
    if (!mounted) return;
    _toast(created ? 'Yerel oda kuruldu' : 'Oda kurulamadı, tekrar deneyin');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = ThemeState.accent.value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Oda'),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: accent,
          labelColor: accent,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(icon: Icon(Icons.graphic_eq), text: 'Yerel Oda'),
            Tab(icon: Icon(Icons.favorite), text: 'Kitaplığım'),
          ],
        ),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          RoomService.instance,
          Library.instance,
          PlayerController.instance,
        ]),
        builder: (context, _) => TabBarView(
          controller: _tabs,
          children: [
            _roomTab(accent),
            _libraryTab(accent),
          ],
        ),
      ),
    );
  }

  // ── Yerel Oda ──

  Widget _roomTab(Color accent) {
    final room = RoomService.instance;
    if (!room.inRoom) return _entry(accent);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _roomHeader(room, accent),
        const SizedBox(height: 12),
        _members(accent),
        const SizedBox(height: 12),
        _nowPlaying(accent),
        const SizedBox(height: 12),
        _queue(room),
        const SizedBox(height: 12),
        _chatCard(accent),
      ],
    );
  }

  Widget _entry(Color accent) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                accent.withValues(alpha: 0.32),
                const Color(0xFF242424),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Yerel Oda',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 8),
              Text(
                'Oda kur, çalma listeni yönet. Senkronizasyon için harici sunucu gerekir; bu oda yalnızca bu cihazda çalışır.',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _displayName,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Görünen adın',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _roomName,
          maxLength: 40,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Oda adı',
            prefixIcon: Icon(Icons.meeting_room_outlined),
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _password,
          obscureText: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Şifre (isteğe bağlı)',
            prefixIcon: Icon(Icons.lock_outline),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _createRoom,
          icon: const Icon(Icons.add),
          label: const Text('Yerel odayı kur'),
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            minimumSize: const Size.fromHeight(48),
          ),
        ),
      ],
    );
  }

  Widget _roomHeader(RoomService room, Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: accent.withValues(alpha: 0.2),
              child: Icon(Icons.music_note, color: accent, size: 26),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    room.roomName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${room.roomId} · ${room.members.length} cihaz · Yerel mod',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (room.isHost)
              IconButton(
                tooltip: 'Oda adını değiştir',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => _renameDialog(room),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: room.leave,
                icon: const Icon(Icons.logout),
                label: const Text('Odadan çık'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: Colors.white24),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: _pickAvatar,
                icon: const Icon(Icons.image_outlined),
                label: const Text('Avatar'),
                style: FilledButton.styleFrom(backgroundColor: accent),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _renameDialog(RoomService room) {
    final controller = TextEditingController(text: room.roomName);
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Oda adını değiştir'),
        content: TextField(
          controller: controller,
          maxLength: 40,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Yeni oda adı'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () {
              room.renameRoom(controller.text);
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(
              backgroundColor: ThemeState.accent.value,
            ),
            child: const Text('Kaydet'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Widget _members(Color accent) {
    final members = RoomService.instance.members;
    final image = _avatarImage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Üyeler (${members.length})', style: _sectionTitle),
        const SizedBox(height: 8),
        SizedBox(
          height: 76,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            itemCount: members.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final member = members[i];
              return SizedBox(
                width: 76,
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: accent.withValues(alpha: 0.2),
                      backgroundImage: image,
                      child: image == null
                          ? Icon(Icons.person, color: accent, size: 24)
                          : null,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      member.isHost ? '${member.name} (Ev sahibi)' : member.name,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _nowPlaying(Color accent) {
    final player = PlayerController.instance;
    final track = player.current;
    if (track == null) return const SizedBox.shrink();
    return Card(
      color: accent.withValues(alpha: 0.12),
      child: ListTile(
        leading: _thumbnail(track),
        title: Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          track.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Sıraya ekle',
              icon: const Icon(Icons.add, size: 20),
              onPressed: () => RoomService.instance.addToQueue(track),
            ),
            IconButton(
              tooltip: player.playing ? 'Duraklat' : 'Oynat',
              icon: Icon(
                player.playing ? Icons.pause : Icons.play_arrow,
                color: accent,
              ),
              onPressed: player.toggle,
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumbnail(Track track, {double size = 48}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: track.thumb,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => Container(
          color: const Color(0xFF242424),
          child: Icon(Icons.music_note, size: size * 0.6),
        ),
      ),
    );
  }

  Widget _queue(RoomService room) {
    if (room.queue.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sıra (${room.queue.length})', style: _sectionTitle),
        const SizedBox(height: 8),
        SizedBox(
          height: 220,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            itemCount: room.queue.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final track = room.queue[i];
              return Card(
                color: const Color(0xFF1E1E1E),
                child: ListTile(
                  leading: _thumbnail(track),
                  title: Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: 'Sıradan çıkar',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => room.removeFromQueue(i),
                  ),
                  onTap: () => room.playFromQueue(i),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _chatCard(Color accent) {
    return Card(
      color: const Color(0xFF1E1E1E),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sohbet', style: _sectionTitle),
            const SizedBox(height: 8),
            const Text(
              'Sohbet için harici sunucu gerekir. Bu yerel oda yalnızca bu cihazda çalışır.',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              enabled: false,
              decoration: InputDecoration(
                hintText: 'Sunucu bağlanmadan mesaj gönderilemez',
                prefixIcon: Icon(Icons.chat_bubble_outline, color: accent),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Kitaplığım ──

  Widget _libraryTab(Color accent) {
    final library = Library.instance;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _profile(accent),
        const SizedBox(height: 24),
        _strip(
          'Beğenilenler',
          library.liked,
          accent,
          empty: 'Henüz beğenilen şarkı yok.',
        ),
        const SizedBox(height: 24),
        _strip(
          'Dinleme Geçmişi',
          library.history,
          accent,
          empty: 'Henüz dinleme geçmişi yok.',
        ),
      ],
    );
  }

  Widget _profile(Color accent) {
    final image = _avatarImage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Profil', style: _sectionTitle),
        const SizedBox(height: 12),
        Row(
          children: [
            GestureDetector(
              onTap: _pickAvatar,
              child: CircleAvatar(
                radius: 40,
                backgroundColor: accent.withValues(alpha: 0.2),
                backgroundImage: image,
                child: image == null
                    ? Icon(Icons.person, color: accent, size: 40)
                    : null,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    image == null ? 'Avatar yok' : 'Avatar ayarlandı',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Avatara dokunarak değiştir',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Avatar değiştir',
              icon: Icon(Icons.image_outlined, color: accent),
              onPressed: _pickAvatar,
            ),
          ],
        ),
      ],
    );
  }

  Widget _strip(
    String title,
    List<Track> tracks,
    Color accent, {
    required String empty,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('$title (${tracks.length})', style: _sectionTitle),
            if (tracks.isNotEmpty)
              TextButton(
                onPressed: () => PlayerController.instance.playQueue(
                  tracks,
                  0,
                  radio: false,
                ),
                child: Text('Tümünü çal', style: TextStyle(color: accent)),
              ),
          ],
        ),
        const SizedBox(height: 8),
        tracks.isEmpty
            ? Text(empty, style: const TextStyle(color: Colors.white38))
            : SizedBox(
                height: 180,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  itemCount: tracks.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, i) =>
                      _trackCard(tracks[i], tracks, i, accent),
                ),
              ),
      ],
    );
  }

  Widget _trackCard(Track track, List<Track> queue, int index, Color accent) {
    return SizedBox(
      width: 136,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () =>
            PlayerController.instance.playQueue(queue, index, radio: false),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CachedNetworkImage(
                imageUrl: track.thumb,
                width: 136,
                height: 136,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Container(
                  color: const Color(0xFF242424),
                  child: Icon(
                    Icons.music_note,
                    size: 48,
                    color: accent.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              track.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
