import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:cloudtune/core/app_palette.dart';

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/room_service.dart';
import '../core/theme_state.dart';

/// Odalar: internet üzerinden oda kurma/koda katılma ve kişisel kitaplık.
class RoomPage extends StatefulWidget {
  const RoomPage({super.key, this.initialCode, this.initialTab = 0});

  final String? initialCode;
  final int initialTab;

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage>
    with SingleTickerProviderStateMixin {
  static const _displayNameKey = 'room_display_name';

  final ImagePicker _picker = ImagePicker();
  final TextEditingController _displayName = TextEditingController();
  final TextEditingController _roomName = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _joinCode = TextEditingController();
  final TextEditingController _joinPassword = TextEditingController();
  final TextEditingController _chatInput = TextEditingController();

  late final TabController _tabs = TabController(
    length: 2,
    vsync: this,
    initialIndex: widget.initialTab.clamp(0, 1),
  );
  bool _joinedInitial = false;

  @override
  void initState() {
    super.initState();
    unawaited(RoomService.init());
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString(_displayNameKey) ?? '';
      if (mounted && saved.isNotEmpty) _displayName.text = saved;
    });
    final code = widget.initialCode;
    if (code != null && code.isNotEmpty && !_joinedInitial) {
      _joinedInitial = true;
      _joinCode.text = code;
      unawaited(_openJoinDialog());
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    _displayName.dispose();
    _roomName.dispose();
    _password.dispose();
    _joinCode.dispose();
    _joinPassword.dispose();
    _chatInput.dispose();
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
        await RoomService.instance.uploadAvatar('local');
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _createRoom() async {
    final name = _displayName.text.trim();
    if (name.isNotEmpty) await _saveDisplayName(name);
    _toast('Odaya bağlanılıyor…');
    final created = await RoomService.instance.create(
      name: _roomName.text.trim(),
      password: _password.text,
      displayName: name,
    );
    if (!mounted) return;
    _toast(created ? 'Oda kuruldu · kodu paylaş' : 'Oda kurulamadı');
  }

  Future<void> _openJoinDialog() async {
    final name = _displayName.text.trim();
    if (name.isNotEmpty) await _saveDisplayName(name);
    if (!mounted) return;
    final codeController = TextEditingController(text: _joinCode.text.trim());
    final passController = TextEditingController(text: _joinPassword.text);
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Odaya katıl'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: codeController,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Oda kodu',
                prefixIcon: Icon(Icons.meeting_room_outlined),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: passController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Şifre (varsa)',
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: ThemeState.accent.value,
            ),
            child: const Text('Katıl'),
          ),
        ],
      ),
    );
    if (result != true || !mounted) return;

    _joinCode.text = codeController.text.trim();
    _joinPassword.text = passController.text;
    _toast('Odaya bağlanılıyor…');
    final joined = await RoomService.instance.join(
      code: _joinCode.text,
      password: _joinPassword.text,
      displayName: name,
    );
    if (!mounted) return;
    _toast(joined
        ? 'Odaya katıldın'
        : (RoomService.instance.error.isEmpty
            ? 'Katılım başarısız'
            : RoomService.instance.error));
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _copyInvite() async {
    final room = RoomService.instance;
    if (!room.inRoom) return;
    final text = room.inviteLink +
        (room.hasPassword ? '\nŞifre: ${room.roomPassword}' : '');
    await Clipboard.setData(ClipboardData(text: text));
    _toast('Davet bağlantısı kopyalandı');
  }

  @override
  Widget build(BuildContext context) {
    final accent = ThemeState.accent.value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Odalar'),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: accent,
          labelColor: accent,
          unselectedLabelColor: AppPalette.textMuted,
          tabs: const [
            Tab(icon: Icon(Icons.graphic_eq), text: 'Odalar'),
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
          children: [_roomTab(accent), _libraryTab(accent)],
        ),
      ),
    );
  }

  Widget _roomTab(Color accent) {
    final room = RoomService.instance;
    if (room.busy) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!room.inRoom) return _entry(accent);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _roomHeader(room, accent),
        const SizedBox(height: 12),
        _members(accent),
        const SizedBox(height: 12),
        _nowPlaying(room, accent),
        const SizedBox(height: 12),
        _queue(room),
        const SizedBox(height: 12),
        _chatCard(room, accent),
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
              colors: [accent.withValues(alpha: 0.32), AppPalette.card],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Odalar',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              SizedBox(height: 8),
              Text(
                'Oda kur, kodu paylaş ya da başka bir odanın koduyla '
                'internet üzerinden katıl. Şarkılar her cihazda kendi '
                'bağlantısıyla çalınır; oda durumu eşzamanlı tutulur.',
                style: TextStyle(color: AppPalette.textMuted, fontSize: 13),
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
        const SizedBox(height: 20),
        Text('Yeni oda kur', style: _sectionTitle),
        const SizedBox(height: 8),
        TextField(
          controller: _roomName,
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: 'Oda adı',
            prefixIcon: Icon(Icons.meeting_room_outlined),
          ),
        ),
        TextField(
          controller: _password,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Şifre (isteğe bağlı)',
            prefixIcon: Icon(Icons.lock_outline),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _createRoom,
          icon: const Icon(Icons.add),
          label: const Text('Odayı kur'),
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            minimumSize: const Size.fromHeight(48),
          ),
        ),
        const SizedBox(height: 24),
        Text('Kodla katıl', style: _sectionTitle),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _openJoinDialog,
          icon: const Icon(Icons.login),
          label: const Text('Oda kodunu gir'),
          style: OutlinedButton.styleFrom(
            foregroundColor: accent,
            side: BorderSide(color: accent.withValues(alpha: 0.6)),
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
                  Text(room.roomName,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    '${room.roomId} · ${room.members.length} dinleyici · '
                    '${room.isHost ? 'Ev sahibi' : 'Katılımcı'}',
                    style:
                        TextStyle(color: AppPalette.textSubtle, fontSize: 12),
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
                label: const Text('Çık'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppPalette.textMuted,
                  side: BorderSide(color: AppPalette.iconFaint),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: _copyInvite,
                icon: const Icon(Icons.share),
                label: const Text('Kodu paylaş'),
                style: FilledButton.styleFrom(backgroundColor: accent),
              ),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.sync),
          title: const Text('Oda ile eşzamanlı çal'),
          subtitle: const Text('Ev sahibinin parçasını otomatik oynat.'),
          value: room.autoSync,
          onChanged: room.setAutoSync,
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
        Text('Dinleyiciler (${members.length})', style: _sectionTitle),
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
                      backgroundImage: member.clientId == RoomService.clientId
                          ? image
                          : null,
                      child: member.clientId == RoomService.clientId &&
                              image != null
                          ? null
                          : Icon(Icons.person, color: accent, size: 24),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      member.isHost
                          ? '${member.name} (Ev sahibi)'
                          : member.name,
                      style: const TextStyle(
                          fontSize: 10, fontWeight: FontWeight.w600),
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

  Widget _nowPlaying(RoomService room, Color accent) {
    final player = PlayerController.instance;
    final track = player.current;
    final remote = room.playback;
    final title = track?.title ?? remote?['title']?.toString() ?? 'Parça yok';
    final artist = track?.artist ?? remote?['artist']?.toString() ?? '';
    final id = track?.id ?? remote?['id']?.toString() ?? '';

    return Card(
      color: accent.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: id.isEmpty
                  ? Container(
                      width: 48,
                      height: 48,
                      color: AppPalette.card,
                      child: const Icon(Icons.music_note, size: 26),
                    )
                  : CachedNetworkImage(
                      imageUrl: 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        width: 48,
                        height: 48,
                        color: AppPalette.card,
                        child: const Icon(Icons.music_note, size: 26),
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppPalette.textSubtle, fontSize: 12)),
                ],
              ),
            ),
            if (track != null)
              IconButton(
                tooltip: player.playing ? 'Duraklat' : 'Oynat',
                icon: Icon(player.playing ? Icons.pause : Icons.play_arrow,
                    color: accent),
                onPressed: player.toggle,
              ),
            IconButton(
              tooltip: 'Sıraya ekle',
              icon: const Icon(Icons.add, size: 20),
              onPressed: track == null ? null : () => room.addToQueue(track),
            ),
          ],
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
                color: AppPalette.cardAlt,
                child: ListTile(
                  leading: _thumbnail(track),
                  title: Text(track.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(track.artist,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: room.isHost
                      ? IconButton(
                          tooltip: 'Sıradan çıkar',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => room.removeFromQueue(i),
                        )
                      : null,
                  onTap: () => room.playFromQueue(i),
                ),
              );
            },
          ),
        ),
      ],
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
          color: AppPalette.card,
          child: Icon(Icons.music_note, size: size * 0.6),
        ),
      ),
    );
  }

  Widget _chatCard(RoomService room, Color accent) {
    final reactions = room.reactions.entries.toList();
    return Card(
      color: AppPalette.cardAlt,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sohbet', style: _sectionTitle),
            const SizedBox(height: 8),
            SizedBox(
              height: 160,
              child: room.chat.isEmpty
                  ? Center(
                      child: Text('Henüz mesaj yok.',
                          style: TextStyle(color: AppPalette.textFaint)))
                  : ListView.builder(
                      itemCount: room.chat.length,
                      itemBuilder: (context, i) {
                        final message = room.chat[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text.rich(
                            TextSpan(
                              text: '${message.name}: ',
                              style: TextStyle(
                                  color: accent, fontWeight: FontWeight.w700),
                              children: [
                                TextSpan(
                                  text: message.text,
                                  style: TextStyle(
                                      color: AppPalette.textMuted,
                                      fontWeight: FontWeight.normal),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chatInput,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (value) {
                      room.sendChat(value);
                      _chatInput.clear();
                    },
                    decoration: const InputDecoration(
                      hintText: 'Mesaj yaz…',
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Gönder',
                  icon: Icon(Icons.send, color: accent),
                  onPressed: () {
                    room.sendChat(_chatInput.text);
                    _chatInput.clear();
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final emoji in ['❤️', '🔥', '👏', '😂'])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text(
                          reactions
                                      .firstWhere(
                                        (entry) => entry.key == emoji,
                                        orElse: () => MapEntry(emoji, 0),
                                      )
                                      .value ==
                                  0
                              ? emoji
                              : '$emoji ${reactions.firstWhere((entry) => entry.key == emoji).value}',
                        ),
                        onPressed: () => room.react(emoji),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _libraryTab(Color accent) {
    final library = Library.instance;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _profile(accent),
        const SizedBox(height: 24),
        _strip('Beğenilenler', library.liked, accent,
            empty: 'Henüz beğenilen şarkı yok.'),
        const SizedBox(height: 24),
        _strip('Dinleme Geçmişi', library.history, accent,
            empty: 'Henüz dinleme geçmişi yok.'),
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
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text('Avatara dokunarak değiştir',
                      style: TextStyle(
                          color: AppPalette.textSubtle, fontSize: 12)),
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

  Widget _strip(String title, List<Track> tracks, Color accent,
      {required String empty}) {
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
            ? Text(empty, style: TextStyle(color: AppPalette.textFaint))
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
                  color: AppPalette.card,
                  child: Icon(Icons.music_note,
                      size: 48, color: accent.withValues(alpha: 0.7)),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(track.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppPalette.textSubtle, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
