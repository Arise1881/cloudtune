import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:cloudtune/core/app_palette.dart';

import 'core/download_service.dart';
import 'core/library.dart';
import 'core/link_handler.dart';
import 'core/link_resolver.dart';
import 'core/player_controller.dart';
import 'core/repair_bot.dart';
import 'core/room_service.dart';
import 'core/settings_service.dart';
import 'core/test_tracks.dart';
import 'core/theme_state.dart';
import 'core/update_service.dart';
import 'l10n/app_strings.dart';
import 'screens/room_page.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Library.instance.init();
  await SettingsService.instance.init();
  // "Sistem" seçiliyken cihaz teması değişirse palet ve ThemeData yenilenir.
  WidgetsBinding.instance.platformDispatcher.onPlatformBrightnessChanged = () {
    ThemeState.applyThemeMode(
      SettingsService.instance.themeMode,
      platform: WidgetsBinding.instance.platformDispatcher.platformBrightness,
    );
  };
  await DownloadService.instance.init();
  await RoomService.init();
  // Odalar her cihazda, uygulama açılır açılmaz görünsün. RoomPage yalnızca
  // zaten başlatılmış dinleyiciye abone olur; keşif bağlantısı globaldir.
  unawaited(RoomService.instance.startDiscovery());

  await AudioService.init(
    builder: () => PlayerController.instance,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.cloudtune.app.audio',
      androidNotificationChannelName: 'CloudTune',
      // Duraklatınca foreground servisi kapatmak ses oturumunu dağıtıyor,
      // geri açarken klik/kırılma oluyordu. Servis açık kalsın. audio_service
      // bunun için ongoing=false zorunlu kılar.
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
      androidNotificationIcon: 'mipmap/ic_launcher',
    ),
  );
  await PlayerController.instance.initAudioSession();

  // Ekolayzer efektini bir kez, açılışta uygula. Parça başına uygulanırsa
  // ExoPlayer'da kısa ses kesintileri/çizirti oluşuyordu.
  unawaited(PlayerController.instance.refreshEqualizer());

  unawaited(UpdateService.instance.init());
  unawaited(RepairBot.start());

  runApp(const CloudTuneApp());
}

class CloudTuneApp extends StatefulWidget {
  const CloudTuneApp({super.key});

  @override
  State<CloudTuneApp> createState() => _CloudTuneAppState();
}

class _CloudTuneAppState extends State<CloudTuneApp> {
  final AppLinks _appLinks = AppLinks();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<Uri>? _linkSub;
  String? _lastLink;
  String? _pendingRoomCode;
  String? _pendingRoomPassword;
  DateTime _lastLinkAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _listenLinks();
    AudioService.notificationClicked.listen((clicked) {
      if (!clicked || !mounted) return;
      _navigatorKey.currentState?.popUntil((r) => r.isFirst);
    });
  }

  Future<void> _listenLinks() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) unawaited(_openLink(initial.toString()));
    } catch (_) {
      // Bağlantı okunamazsa sessizce geç.
    }
    _linkSub = _appLinks.uriLinkStream.listen(
      (uri) => unawaited(_openLink(uri.toString())),
      onError: (_) {},
    );
  }

  Future<void> _openLink(String link) async {
    // app_links ilk bağlantıyı hem getInitialLink hem uriLinkStream üzerinden
    // verebilir. İkinci çağrı aynı kuyruğu yeniden yükleyip ilk akışı keser.
    final now = DateTime.now();
    if (link == _lastLink &&
        now.difference(_lastLinkAt) < const Duration(seconds: 2)) {
      return;
    }
    _lastLink = link;
    _lastLinkAt = now;

    final uri = Uri.tryParse(link);
    // Yalnizca emulator dogrulamasi icin; ana sayfada hicbir yerde sunulmaz.
    if (kDebugMode &&
        uri != null &&
        uri.scheme == 'cloudtune' &&
        uri.host == 'test' &&
        uri.pathSegments.contains('play')) {
      unawaited(PlayerController.instance.playQueue(
        TestTracks.shuffled(),
        0,
        radio: false,
      ));
      return;
    }
    final isWebRoomLink = uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.toLowerCase() == 'cloudtune.app' &&
        uri.pathSegments.isNotEmpty &&
        uri.pathSegments.first.toLowerCase() == 'room';
    final isRoom = uri != null &&
        ((uri.scheme == 'cloudtune' && uri.host == 'room') ||
            isWebRoomLink);
    if (isRoom) {
      final segments = uri.pathSegments;
      final code = !isWebRoomLink
          ? (segments.isNotEmpty ? segments.first : '')
          : (segments.length > 1 ? segments[1] : '');
      if (code.isNotEmpty) {
        // Davet linkindeki ?p= parolası, şifreli odaya katılım için gerekli.
        final password = uri.queryParameters['p'] ?? '';
        _openRoomPage(code.toUpperCase(), password);
      }
      return;
    }
    if (!YoutubeLinkResolver.isYoutubeLink(link)) return;
    await LinkHandler.open(link);
  }

  /// İlk bağlantı `runApp` tamamlanmadan gelebilir; Navigator henüz yoksa
  /// kod bekletilir ve ilk frame'den sonra açılır.
  void _openRoomPage(String code, String password) {
    final state = _navigatorKey.currentState;
    if (state == null || !state.mounted) {
      _pendingRoomCode = code;
      _pendingRoomPassword = password;
      return;
    }
    unawaited(state.push(
      MaterialPageRoute(
        builder: (_) => RoomPage(
          initialCode: code,
          initialPassword: password,
        ),
      ),
    ));
  }

  void _flushPendingRoomLink() {
    final code = _pendingRoomCode;
    if (code == null) return;
    _pendingRoomCode = null;
    _openRoomPage(code, _pendingRoomPassword ?? '');
    _pendingRoomPassword = null;
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _flushPendingRoomLink());
    return ListenableBuilder(
      listenable: ThemeState.accent,
      builder: (context, _) {
        return ListenableBuilder(
          listenable: ThemeState.brightness,
          builder: (context, _) {
            return ListenableBuilder(
              listenable: SettingsService.instance,
              builder: (context, _) {
                final accent = ThemeState.accent.value;
                final themeMode = SettingsService.instance.themeMode;
                // SettingsService değişince bu builder yeniden kurulur; dil
                // değişimi MaterialApp.locale üzerinden anında yansır.
                return MaterialApp(
                  navigatorKey: _navigatorKey,
                  title: 'CloudTune',
                  debugShowCheckedModeBanner: false,
                  theme: _theme(accent, Brightness.light, oled: false),
                  darkTheme: _theme(accent, Brightness.dark,
                      oled: SettingsService.instance.oledBlack),
                  themeMode: themeMode,
                  builder: (context, child) {
                    final mq = MediaQuery.of(context);
                    final clamped =
                        mq.textScaler.clamp(minScaleFactor: 0.9, maxScaleFactor: 1.2);
                    return MediaQuery(
                      data: mq.copyWith(textScaler: clamped),
                      child: child ?? const SizedBox.shrink(),
                    );
                  },
                  localizationsDelegates: const [
                    AppStringsDelegate(),
                    AppMaterialLocalizationsDelegate(),
                    AppCupertinoLocalizationsDelegate(),
                  ],
                  supportedLocales: AppStrings.supportedLocales,
                  locale: SettingsService.instance.locale,
                  home: const HomePage(),
                );
              },
            );
          },
        );
      },
    );
  }

  ThemeData _theme(Color accent, Brightness brightness, {required bool oled}) {
    final dark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor:
          dark ? (oled ? Colors.black : const Color(0xFF121212)) : Colors.white,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: brightness,
        primary: accent,
        surface: dark ? AppPalette.surface : Colors.white,
      ),
      cardColor: dark ? AppPalette.card : const Color(0xFFF1F1F1),
      canvasColor: dark ? AppPalette.surface : Colors.white,
      dividerColor: dark ? const Color(0x1FFFFFFF) : const Color(0x1A181818),
      hintColor: dark ? const Color(0x8AFFFFFF) : const Color(0x8A181818),
    );
  }
}
