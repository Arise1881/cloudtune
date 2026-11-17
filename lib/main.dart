import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'core/download_service.dart';
import 'core/library.dart';
import 'core/link_handler.dart';
import 'core/link_resolver.dart';
import 'core/local_sync_service.dart'
    if (dart.library.html) 'core/local_sync_web.dart';
import 'core/player_controller.dart';
import 'core/proxy_service.dart';
import 'core/repair_bot.dart';
import 'core/room_service.dart';
import 'core/settings_service.dart';
import 'core/theme_state.dart';
import 'core/update_service.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Library.instance.init();
  await SettingsService.instance.init();
  await ProxyService.instance.init();
  await LocalSyncService.instance.init();
  if (LocalSyncService.instance.enabled) {
    unawaited(LocalSyncService.instance.start());
  }
  await DownloadService.instance.init();
  await RoomService.init();

  await AudioService.init(
    builder: () => PlayerController.instance,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.cloudtune.app.audio',
      androidNotificationChannelName: 'CloudTune',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidNotificationIcon: 'mipmap/ic_launcher',
    ),
  );

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
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    _listenLinks();
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
    if (!YoutubeLinkResolver.isYoutubeLink(link)) return;
    await LinkHandler.open(link);
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeState.accent,
      builder: (context, _) {
        return ListenableBuilder(
          listenable: SettingsService.instance,
          builder: (context, _) {
            final accent = ThemeState.accent.value;
            final themeMode = SettingsService.instance.themeMode;
            return MaterialApp(
              title: 'CloudTune',
              debugShowCheckedModeBanner: false,
              theme: _theme(accent, themeMode, SettingsService.instance.oledBlack),
              home: const HomePage(),
            );
          },
        );
      },
    );
  }

  ThemeData _theme(Color accent, ThemeMode mode, bool oled) {
    final dark = mode == ThemeMode.dark ||
        (mode == ThemeMode.system &&
            MediaQuery.of(context).platformBrightness == Brightness.dark);
    if (!dark) {
      return ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.light,
          primary: accent,
          surface: Colors.white,
        ),
      );
    }
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: oled ? Colors.black : const Color(0xFF121212),
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.dark,
        primary: accent,
        surface: const Color(0xFF181818),
      ),
    );
  }
}
