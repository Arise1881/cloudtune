import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'core/library.dart';
import 'core/link_handler.dart';
import 'core/link_resolver.dart';
import 'core/player_controller.dart';
import 'core/repair_bot.dart';
import 'core/theme_state.dart';
import 'core/update_service.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Library.instance.init();
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
  StreamSubscription<Uri>? _sub;

  @override
  void initState() {
    super.initState();
    _initLinks();
  }

  Future<void> _initLinks() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) unawaited(_openLink(initial.toString()));
    } catch (_) {}
    _sub = _appLinks.uriLinkStream.listen(
      (uri) => unawaited(_openLink(uri.toString())),
      onError: (_) {},
    );
  }

  Future<void> _openLink(String link) async {
    if (!YoutubeLinkResolver.isYoutubeLink(link)) return;
    // Baglantilar sessizce acilir; basarisizlikta onarim botu devralir.
    await LinkHandler.open(link);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeState.accent,
      builder: (context, _) {
        final accent = ThemeState.accent.value;
        return MaterialApp(
          title: 'CloudTune',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xFF121212),
            colorScheme: ColorScheme.fromSeed(
              seedColor: accent,
              brightness: Brightness.dark,
              primary: accent,
              surface: const Color(0xFF181818),
            ),
          ),
          home: const HomePage(),
        );
      },
    );
  }
}
