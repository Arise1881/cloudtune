import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'core/link_handler.dart';
import 'core/link_resolver.dart';
import 'ui/home_page.dart';

final GlobalKey<ScaffoldMessengerState> messengerKey =
    GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.cloudtune.app.audio',
    androidNotificationChannelName: 'CloudTune',
    androidNotificationOngoing: true,
  );
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
      if (initial != null) _openLink(initial.toString());
    } catch (_) {}
    _sub = _appLinks.uriLinkStream.listen((uri) => _openLink(uri.toString()));
  }

  Future<void> _openLink(String link) async {
    if (!YoutubeLinkResolver.isYoutubeLink(link)) return;
    final error = await LinkHandler.open(link);
    if (error != null) {
      messengerKey.currentState?.showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF1DB954);
    return MaterialApp(
      title: 'CloudTune',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: messengerKey,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: ColorScheme.fromSeed(
          seedColor: green,
          brightness: Brightness.dark,
          primary: green,
          surface: const Color(0xFF181818),
        ),
      ),
      home: const HomePage(),
    );
  }
}
