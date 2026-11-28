import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:cloudtune/core/app_palette.dart';

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/library.dart';
import '../core/models.dart';
import '../core/player_controller.dart';
import '../core/room_service.dart';
import '../core/theme_state.dart';
import '../ui/cover_image.dart';

/// Odalar: internet üzerinden oda kurma/koda katılma ve kişisel kitaplık.
class RoomPage extends StatefulWidget {
  const RoomPage({
    super.key,
    this.initialCode,
    this.initialPassword,
    this.initialTab = 0,
  });

  final String? initialCode;
  final String? initialPassword;
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
  final ScrollController _chatScroll = ScrollController();

  late final TabController _tabs = TabController(
    length: 2,
    vsync: this,
    initialIndex: widget.initialTab.clamp(0, 1),
  );
  bool _joinedInitial = false;

  @override
  void initState() {
    super.initState();
    // Odalar sekmesi açıkken aktif odaları dinle; şifre taşınmaz.
    unawaited(RoomService.init().then((_) => RoomService.instance.startDiscovery()));
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString(_displayNameKey) ?? '';
      if (mounted && saved.isNotEmpty) _displayName.text = saved;
    });
    final code = widget.initialCode;
    if (code != null && code.isNotEmpty && !_joinedInitial) {
      _joinedInitial = true;
      _joinCode.text = code;
      _joinPassword.text = widget.initialPassword ?? '';
      // Davet bağlantısı hızlı katılım: şifre linkte varsa sorulmaz, yoksa
      // önce şifresiz denenir; başarısız olursa kod giriş diyaloğu açılır.
      // initState bitmeden ScaffoldMessenger/Theme erişimi yapılamaz; ilk
      // frame'den sonra hızlı katılımı başlat.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_joinFromInvite());
      });
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
    _chatScroll.dispose();
    super.dispose();
  }

  TextStyle? get _sectionTitle => Theme.of(context)
      .textTheme
      .titleMedium
      ?.copyWith(fontWeight: FontWeight.w700);

  ImageProvider? get _avatarImage {
    final path = Library.instance.avatarPath;
    if (path.isEmpty || !File(path).existsSync()) return null;
    // Library avatarı versiyonlu dosya adıyla kaydeder; cache key de değişir.
    return FileImage(File(path));
  }

  /// Kitaplıktaki avatarı oda kanalına göndermek için sıkıştırılmış JPEG
  /// dataUrl'e çevirir. Yaklaşık 100KB üstü görseller gönderilmez.
  Future<String> _avatarDataUrl() async {
    final path = Library.instance.avatarPath;
    if (path.isEmpty) return '';
    final file = File(path);
    if (!file.existsSync()) return '';
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > 100 * 1024) return '';
    return 'data:image/jpeg;base64,${base64Encode(bytes)}';
  }

  Future<void> _publishMyAvatar() async {
    if (!RoomService.instance.inRoom) return;
    final url = await _avatarDataUrl();
    if (url.isNotEmpty) await RoomService.instance.uploadAvatar(url);
  }

  /// Uzak üye avatarı yalnızca açık onay verildiyse gösterilir.
  ImageProvider? _memberAvatar(RoomMember member) {
    if (member.clientId == RoomService.clientId) return _avatarImage;
    if (!RoomService.instance.remoteDataAllowed) return null;
    final url = member.avatar;
    if (!url.startsWith('data:image/')) return null;
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    try {
      return MemoryImage(base64Decode(url.substring(comma + 1)));
    } catch (_) {
      return null;
    }
  }

  /// Diğer cihazın oda bilgilerini görmek için uygulama içi onay.
  Future<bool> _ensureRemoteDataConsent() async {
    if (RoomService.instance.remoteDataAllowed) return true;
    final granted = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cihaz bilgisi erişimi'),
        content: const Text(
          'Diğer cihazın oda bilgilerini görmek için izin veriyor musun?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hayır'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: ThemeState.accent.value,
            ),
            child: const Text('İzin ver'),
          ),
        ],
      ),
    );
    if (granted == true) await RoomService.instance.grantRemoteData();
    return granted == true;
  }

  Future<void> _saveDisplayName(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_displayNameKey, value);
  }

  Future<void> _pickAvatar() async {
    try {
      // 256px/JPEG 72 kalite: dataUrl yaklaşık 100KB sınırında kalır.
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 256,
        maxHeight: 256,
        imageQuality: 72,
      );
      if (picked == null) return;
      // Library seçilen dosyayı versiyonlu adla kopyalar; ayrıca kopya
      // oluşturmayalım, oda avatarı da aynı kaynaktan yayınlansın.
      await Library.instance.setAvatar(picked.path);
      if (RoomService.instance.inRoom) await _publishMyAvatar();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _createRoom() async {
    final name = _displayName.text.trim();
    if (name.isNotEmpty) await _saveDisplayName(name);
    _toast('Odaya bağlanılıyor…');
    // Avatarı katılımın içinde gönder; ack sonrası ikinci yayını bekleme.
    final avatar = await _avatarDataUrl();
    final created = await RoomService.instance.create(
      name: _roomName.text.trim(),
      password: RoomService.normalizePassword(_password.text),
      avatar: avatar,
      displayName: name,
    );
    if (!mounted) return;
    if (created) {
      await _publishMyAvatar();
      await _ensureRemoteDataConsent();
      _toast('Oda kuruldu · kodu paylaş');
    } else {
      _toast(RoomService.instance.error.isEmpty
          ? 'Oda kurulamadı'
          : RoomService.instance.error);
    }
  }

  /// Kod/şifre onaylandıktan sonra gerçek katılımı yapar. Sonuç tipi hata
  /// mesajını doğrudan taşır; "Oda bulunamadı veya şifre yanlış" net görünür.
  Future<bool> _performJoin({
    required String code,
    required String password,
    String? displayName,
    bool fromInvite = false,
  }) async {
    final name = displayName ?? _displayName.text.trim();
    if (name.isNotEmpty) await _saveDisplayName(name);
    // Davetle katılımda ek onay diyaloğu gösterilmez; oda işlevleri
    // (çalma, sıra, sohbet) zaten çalışır. Avatar gizliliği isteğe bağlıdır.
    final allowed = fromInvite
        ? true
        : await _ensureRemoteDataConsent();
    if (!mounted) return false;
    _toast('Odaya bağlanılıyor…');
    final avatar = await _avatarDataUrl();
    final result = await RoomService.instance.joinWithResult(
      code: code,
      password: password,
      avatar: avatar,
      displayName: name,
    );
    if (!mounted) return result.ok;
    if (result.ok) {
      await _publishMyAvatar();
      _toast(allowed ? 'Odaya katıldın' : 'Odaya katıldın · uzak avatarlar gizli');
      // Katılımdan sonra sohbet aşağıda görünür; listeyi en alta kaydır.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_chatScroll.hasClients) {
          _chatScroll.jumpTo(_chatScroll.position.maxScrollExtent);
        }
      });
    } else {
      _toast(result.error.isEmpty ? 'Katılım başarısız' : result.error);
    }
    return result.ok;
  }

  /// `?p=` içeren bağlantı şifreyi sormaz; şifresiz oda doğrudan açılır.
  /// Başarısızlıkta kullanıcıya şifre girmesi için kod diyaloğu gösterilir.
  Future<void> _joinFromInvite([RoomInvite? parsed]) async {
    final invite = parsed ??
        (RoomService.parseInvite(_joinCode.text) ??
            RoomInvite(
              code: RoomService.normalizeCode(_joinCode.text),
              password: '',
            ));
    if (RoomService.normalizeCode(invite.code).isEmpty) {
      _toast('Geçersiz davet bağlantısı');
      return;
    }
    _joinCode.text = invite.code;
    _joinPassword.text = invite.password;
    final ok = await _performJoin(
      code: invite.code,
      password: invite.password,
      fromInvite: true,
    );
    if (!mounted || ok) return;
    if (invite.password.isEmpty) {
      await _openJoinDialog(code: invite.code);
    }
  }

  Future<void> _openJoinDialog({String? code}) async {
    final name = _displayName.text.trim();
    if (name.isNotEmpty) await _saveDisplayName(name);
    if (!mounted) return;
    final codeController =
        TextEditingController(text: RoomService.normalizeCode(code ?? _joinCode.text));
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
                labelText: 'Oda kodu veya davet bağlantısı',
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
    if (result != true || !mounted) {
      codeController.dispose();
      passController.dispose();
      return;
    }

    // Kodu da kopyalayıp yapıştıranlar için link içinden şifre çözülür.
    final invite = RoomService.parseInvite(codeController.text) ??
        RoomInvite(
          code: RoomService.normalizeCode(codeController.text),
          password: '',
        );
    final pass = RoomService.normalizePassword(passController.text);
    codeController.dispose();
    passController.dispose();

    _joinCode.text = invite.code;
    _joinPassword.text = pass.isEmpty ? invite.password : pass;
    await _performJoin(
      code: _joinCode.text,
      password: _joinPassword.text,
      displayName: name,
    );
  }

  /// Paylaşılan davet bağlantısını yapıştırır; `?p=` şifresi alanı doldurur.
  Future<void> _pasteInvite() async {
    final controller = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Davet bağlantısını yapıştır'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Bağlantı veya oda kodu',
            hintText: 'http://cloudtune.app/room/KOD?p=sifre',
          ),
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
            child: const Text('Devam'),
          ),
        ],
      ),
    );
    final invite = accepted == true ? RoomService.parseInvite(controller.text) : null;
    controller.dispose();
    if (invite == null) {
      if (accepted == true) _toast('Geçersiz davet bağlantısı');
      return;
    }
    _joinCode.text = invite.code;
    _joinPassword.text = invite.password;
    // Linkte şifre varsa doğrudan katıl; yoksa hızlıca şifresiz dene.
    await _joinFromInvite(invite);
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
    // inviteLink şifreyi `?p=` olarak taşır; ayrı satıra gerek yok.
    await Clipboard.setData(ClipboardData(text: room.inviteLink));
    _toast(room.hasPassword
        ? 'Davet bağlantısı kopyalandı (şifre dahil)'
        : 'Davet bağlantısı kopyalandı');
  }

  @override
  Widget build(BuildContext context) {
    final accent = ThemeState.accent.value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Odalar (Beta)'),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: accent,
          labelColor: accent,
          unselectedLabelColor: AppPalette.textMuted,
          tabs: const [
            Tab(icon: Icon(Icons.graphic_eq), text: 'Odalar (Beta)'),
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
          children: [_roomTab(context, accent), _libraryTab(accent)],
        ),
      ),
    );
  }

  Widget _roomTab(BuildContext context, Color accent) {
    final room = RoomService.instance;
    if (room.busy) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!room.inRoom) return _entry(accent);
    // Sohbet girişi son öğe; sistem navigasyon çubuğu/klavye inset'iyle
    // üst üste binmesin. Ekstra boşluk girişin her cihazda dokunulabilir
    // kalmasını sağlar.
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 24 + bottomInset),
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
        const SizedBox(height: 56),
      ],
    );
  }

  Widget _entry(Color accent) {
    final room = RoomService.instance;
    final found = room.discoveredRooms;
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
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(child: Text('Aktif odalar', style: _sectionTitle)),
            IconButton(
              tooltip: 'Listeyi yenile',
              icon: const Icon(Icons.refresh),
              onPressed: () => unawaited(room.startDiscovery()),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (room.discoveryError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(room.discoveryError,
                style: TextStyle(color: AppPalette.textFaint, fontSize: 12)),
          ),
        if (found.isEmpty)
          Text('Şu anda görünen oda yok. Kodla katılabilirsin.',
              style: TextStyle(color: AppPalette.textFaint, fontSize: 13))
        else
          Column(
            children: [for (final item in found) _discoveryTile(item, accent)],
          ),
        const SizedBox(height: 24),
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
          onPressed: () => _openJoinDialog(),
          icon: const Icon(Icons.login),
          label: const Text('Oda kodunu gir'),
          style: OutlinedButton.styleFrom(
            foregroundColor: accent,
            side: BorderSide(color: accent.withValues(alpha: 0.6)),
            minimumSize: const Size.fromHeight(48),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _pasteInvite,
          icon: const Icon(Icons.content_paste_go),
          label: const Text('Davet yapıştır'),
          style: OutlinedButton.styleFrom(
            foregroundColor: accent,
            side: BorderSide(color: accent.withValues(alpha: 0.6)),
            minimumSize: const Size.fromHeight(48),
          ),
        ),
      ],
    );
  }

  /// Şifresiz odaya tek dokunuşla katılır; şifreli oda parola dialogu açar.
  Widget _discoveryTile(RoomDiscovery item, Color accent) {
    return Card(
      color: AppPalette.cardAlt,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: accent.withValues(alpha: 0.18),
          child: Icon(
            item.hasPassword ? Icons.lock_outline : Icons.meeting_room_outlined,
            color: accent,
            size: 20,
          ),
        ),
        title: Text(item.name.isEmpty ? 'Oda ${item.code}' : item.name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${item.code} · ${item.memberCount} dinleyici'
          '${item.hostName.isEmpty ? '' : ' · ${item.hostName}'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Icon(
          item.hasPassword ? Icons.lock : Icons.login,
          color: accent,
          size: 18,
        ),
        onTap: () {
          if (item.hasPassword) {
            _joinCode.text = item.code;
            _joinPassword.clear();
            unawaited(_openJoinDialog());
          } else {
            unawaited(_performJoin(code: item.code, password: ''));
          }
        },
      ),
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
              final avatar = _memberAvatar(member);
              return SizedBox(
                width: 76,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: member.clientId == RoomService.clientId
                      ? null
                      : () => unawaited(_memberDetail(member)),
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: accent.withValues(alpha: 0.2),
                        backgroundImage: avatar,
                        child: avatar == null
                            ? Icon(Icons.person, color: accent, size: 24)
                            : null,
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
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Katılımcı detayını açmadan önce onay ister; onay yoksa veri gösterilmez.
  Future<void> _memberDetail(RoomMember member) async {
    final room = RoomService.instance;
    final allowed = await _ensureRemoteDataConsent();
    if (!allowed || !mounted) return;
    final avatar = _memberAvatar(member);
    final shortId = member.clientId.length > 8
        ? member.clientId.substring(0, 8)
        : member.clientId;
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: CircleAvatar(
                radius: 28,
                backgroundImage: avatar,
                child: avatar == null ? const Icon(Icons.person) : null,
              ),
              title: Text(member.name),
              subtitle: Text(
                '${member.isHost ? 'Ev sahibi' : 'Dinleyici'} · $shortId',
              ),
            ),
            // Ev sahibi katılımcıyı odadan çıkarabilir veya ev sahipliğini
            // devredebilir; komutlar tüm cihazlara yayılır.
            if (room.isHost && !member.isHost)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          unawaited(room.transferHost(member.clientId));
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.admin_panel_settings_outlined),
                        label: const Text('Ev sahibi yap'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          unawaited(room.kick(member.clientId));
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.person_remove),
                        label: const Text('Çıkar'),
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

  Widget _nowPlaying(RoomService room, Color accent) {
    final player = PlayerController.instance;
    final track = player.current;
    final remote = room.playback;
    final title = track?.title ?? remote?['title']?.toString() ?? 'Parça yok';
    final artist = track?.artist ?? remote?['artist']?.toString() ?? '';
    final id = track?.id ?? remote?['id']?.toString() ?? '';
    final inRoom = room.inRoom;
    // Paylaşılan sıra gelmişse yerel oyuncu henüz parçayı yüklememiş olsa
    // bile düğmeler etkin: komut tüm cihazlara yayılır ve ilk parçayı
    // RoomService yükler. Bu, yavaş bağlantıda "Oynat"ın pasif kalmasını önler.
    final canControl = track != null || room.queue.isNotEmpty || remote != null;

    void toggle() {
      if (inRoom) {
        unawaited(room.togglePlayback());
      } else {
        unawaited(player.toggle());
      }
    }

    return Card(
      color: accent.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: Column(
          children: [
            Row(
              children: [
                id.isEmpty
                    ? Container(
                        width: 48,
                        height: 48,
                        color: AppPalette.card,
                        child: const Icon(Icons.music_note, size: 26),
                      )
                    : CoverImage(
                        url: track?.thumb ??
                            'https://i.ytimg.com/vi/$id/hqdefault.jpg',
                        width: 48,
                        height: 48,
                        iconSize: 26,
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
                IconButton(
                  tooltip: 'Sıraya ekle',
                  icon: const Icon(Icons.add, size: 20),
                  onPressed: track == null
                      ? null
                      : () => inRoom
                          ? unawaited(room.addTrack(track))
                          : unawaited(player.addToQueue(track)),
                ),
              ],
            ),
            // Oda senkronunda konum saate bağlıdır. Yerel kaydırıcı dokunma
            // anında seek komutuyla tüm cihazlara yayılır.
            if (canControl && inRoom && track != null)
              StreamBuilder<Duration>(
                stream: player.positionStream,
                builder: (context, snapshot) {
                  final maxMs = track.duration?.inMilliseconds ?? 0;
                  final posMs = snapshot.data?.inMilliseconds ?? 0;
                  final max = maxMs > 0 ? maxMs.toDouble() : 1.0;
                  final pos = posMs.toDouble().clamp(0.0, max).toDouble();
                  return Column(
                    children: [
                      Slider(
                        value: pos,
                        max: max,
                        activeColor: accent,
                        onChanged: (value) => unawaited(
                          room.seekTo(Duration(milliseconds: value.round())),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_mmss(Duration(milliseconds: posMs)),
                                style: TextStyle(
                                    color: AppPalette.textFaint,
                                    fontSize: 10)),
                            Text(_mmss(track.duration ?? Duration.zero),
                                style: TextStyle(
                                    color: AppPalette.textFaint,
                                    fontSize: 10)),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Önceki',
                  icon: const Icon(Icons.skip_previous),
                  onPressed: canControl
                      ? () => inRoom
                          ? unawaited(room.previous())
                          : unawaited(player.previous())
                      : null,
                ),
                IconButton(
                  tooltip: player.playing ? 'Duraklat' : 'Oynat',
                  icon: Icon(
                      player.playing ? Icons.pause_circle : Icons.play_circle,
                      color: accent,
                      size: 36),
                  onPressed: canControl ? toggle : null,
                ),
                IconButton(
                  tooltip: 'Sonraki',
                  icon: const Icon(Icons.skip_next),
                  onPressed: canControl
                      ? () => inRoom
                          ? unawaited(room.next())
                          : unawaited(player.next())
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _mmss(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
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
                  // Her katılımcı sıradan parça çıkarabilir; komut tüm
                  // cihazlara yayılır (artık yalnızca host'a özel değil).
                  trailing: IconButton(
                    tooltip: 'Sıradan çıkar',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => unawaited(room.removeFromQueue(i)),
                  ),
                  onTap: () => unawaited(room.playAt(i)),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _thumbnail(Track track, {double size = 48}) => CoverImage(
        url: track.thumb,
        width: size,
        height: size,
        iconSize: size * 0.6,
      );

  void _sendChat(RoomService room) {
    final text = _chatInput.text.trim();
    if (text.isEmpty) return;
    room.sendChat(text);
    _chatInput.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.animateTo(
          _chatScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Widget _chatCard(RoomService room, Color accent) {
    final reactions = room.reactions.entries.toList();
    // Yeni mesaj/oda katılımı sonrası sohbeti otomatik alta kaydır.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.jumpTo(_chatScroll.position.maxScrollExtent);
      }
    });
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
                      controller: _chatScroll,
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
                    onSubmitted: (_) => _sendChat(room),
                    decoration: InputDecoration(
                      hintText: 'Mesaj yaz…',
                      isDense: true,
                      // Profil fotoğrafı yoksa kişi simgesi; giriş artık
                      // her cihazda kendi uygulama içi avatarını taşır.
                      prefixIcon: Padding(
                        padding: const EdgeInsets.only(left: 6, right: 4),
                        child: CircleAvatar(
                          radius: 13,
                          backgroundImage: _avatarImage,
                          child: _avatarImage == null
                              ? Icon(Icons.person,
                                  size: 16, color: AppPalette.iconSubtle)
                              : null,
                        ),
                      ),
                      prefixIconConstraints:
                          const BoxConstraints(minWidth: 36, minHeight: 30),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Gönder',
                  icon: Icon(Icons.send, color: accent),
                  onPressed: () => _sendChat(room),
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
                onPressed: () {
                  final room = RoomService.instance;
                  if (room.inRoom) {
                    for (final track in tracks) {
                      unawaited(room.addTrack(track));
                    }
                  } else {
                    unawaited(PlayerController.instance.playQueue(
                      tracks,
                      0,
                      radio: false,
                    ));
                  }
                },
                child: Text(
                  RoomService.instance.inRoom ? 'Odaya ekle' : 'Tümünü çal',
                  style: TextStyle(color: accent),
                ),
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
    final room = RoomService.instance;
    final inRoom = room.inRoom;
    return SizedBox(
      width: 136,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        // Odadayken kart dokunuşu parçayı paylaşılan sıraya ekler. Yerel
        // çalma host state'i tarafından geri alınacağı için kullanılmaz.
        onTap: inRoom
            ? () => unawaited(room.addTrack(track))
            : () => unawaited(
                PlayerController.instance.playQueue(queue, index, radio: false),
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: CachedNetworkImage(
                    imageUrl: track.thumb,
                    width: 136,
                    height: 136,
                    memCacheWidth: 272,
                    memCacheHeight: 272,
                    fadeInDuration: Duration.zero,
                    fadeOutDuration: Duration.zero,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => Container(
                      color: AppPalette.card,
                      child: Icon(Icons.music_note,
                          size: 48, color: accent.withValues(alpha: 0.7)),
                    ),
                  ),
                ),
                if (inRoom)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.9),
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                            width: 30, height: 30),
                        tooltip: 'Odaya ekle',
                        icon: const Icon(Icons.add, size: 20),
                        onPressed: () => unawaited(room.addTrack(track)),
                      ),
                    ),
                  ),
              ],
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
