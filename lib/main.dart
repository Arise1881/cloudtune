import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:provider/provider.dart';

import 'constants.dart';
import 'services/connectivity_service.dart';
import 'services/download_manager.dart';
import 'services/library_store.dart';
import 'services/music_service.dart';
import 'services/player_service.dart';
import 'services/equalizer_service.dart';
import 'services/update_service.dart';
import 'services/room_service.dart';
import 'services/theme_service.dart';
import 'screens/root_screen.dart';
import 'screens/settings_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Masaüstü (Windows/Linux/macOS) için media_kit tabanlı ses motoru.
  // Mobilde native ExoPlayer/AVPlayer korunur.
  if (!Platform.isAndroid && !Platform.isIOS) {
    JustAudioMediaKit.ensureInitialized();
  }
  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)
        .timeout(const Duration(seconds: 3), onTimeout: () {});
  } catch (e) {
    debugPrint('Sistem UI modu uyarısı: $e');
  }

  // Release modunda bile hatalar boş ekran yerine görünür olsun.
  ErrorWidget.builder = (details) {
    return Container(
      color: const Color(0xFF121212),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Text(
        'Melody hata yakaladı:\n${details.exception}',
        textAlign: TextAlign.center,
        maxLines: 6,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white70, fontSize: 13),
      ),
    );
  };

  // İlk kare asla engellenmez: servisler runApp sonrası arka planda kurulur.
  runZonedGuarded(() {
    runApp(const MelodyApp());
    _warmUpServices();
  }, (error, stack) {
    debugPrint('Yakalanmayan hata: $error\n$stack');
  });
}

/// Uygulama açıldıktan SONRA servisleri kurar.
/// Her adım zaman aşımlı ve hata korumalıdır; hiçbiri çalışmayı engelleyemez.
void _warmUpServices() {
  // Arka plan bildirimi yalnız mobilde (just_audio_background desktop
  // backend'i yok; masaüstünde media_kit kullanılıyor).
  if (Platform.isAndroid || Platform.isIOS) {
    _safe('Arka plan', () => JustAudioBackground.init(
          androidNotificationChannelId: 'com.melody.app.playback',
          androidNotificationChannelName: 'Melody Müzik Çalar',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: false,
          preloadArtwork: true,
        ));
  }
  _safe('Kitaplık', () => LibraryStore.instance.init());
  _safe('Akış proxy', () => MusicService.loadStreamProxy());
   _safe('YouTube kaynak', () => MusicService.loadYoutubeEnabled());
  _safe('Ses kalitesi', () => PlayerService.instance.loadQualityPref());
  _safe('Ekolayzer', () => EqualizerService.instance.init());
  _safe('Tema', () => ThemeService.instance.init());
  _safe('Oda', () => RoomService.instance.init());
  UpdateService.instance.init();

  // Son çalınan oturum ilk kare basıldıktan SONRA geri yüklenir.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _safe('Oturum', () => PlayerService.instance.restoreSession());
  });
}

Future<void> _safe(String name, Future<void> Function() task) async {
  try {
    await task().timeout(const Duration(seconds: 4), onTimeout: () {});
  } catch (e) {
    debugPrint('$name başlatma uyarısı: $e');
  }
}

class MelodyApp extends StatelessWidget {
  const MelodyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<MusicService>.value(value: MusicService.instance),
        ChangeNotifierProvider<ConnectivityService>.value(
            value: ConnectivityService.instance),
        ChangeNotifierProvider<LibraryStore>.value(value: LibraryStore.instance),
        ChangeNotifierProvider<DownloadManager>.value(
            value: DownloadManager.instance),
        ChangeNotifierProvider<PlayerService>.value(value: PlayerService.instance),
        ChangeNotifierProvider<UpdateService>.value(
            value: UpdateService.instance),
        ChangeNotifierProvider<EqualizerService>.value(
            value: EqualizerService.instance),
        ChangeNotifierProvider<RoomService>.value(value: RoomService.instance),
        ChangeNotifierProvider<ThemeService>.value(value: ThemeService.instance),
      ],
      child: Consumer<ThemeService>(
        builder: (context, themeService, _) => MaterialApp(
          title: AppStrings.appName,
          debugShowCheckedModeBanner: false,
          theme: _buildTheme(themeService.accent, Brightness.light),
          darkTheme: _buildTheme(themeService.accent, Brightness.dark),
          themeMode: themeService.mode,
          routes: {
            '/settings': (_) => const SettingsScreen(),
          },
          home: const RootScreen(),
        ),
      ),
    );
  }

  ThemeData _buildTheme(Color accent, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final background = dark ? AppColors.background : const Color(0xFFF4F4F4);
    final surface = dark ? AppColors.surface : const Color(0xFFFFFFFF);
    final card = dark ? AppColors.card : const Color(0xFFFFFFFF);
    final textPrimary = dark ? AppColors.textPrimary : const Color(0xFF111111);
    final textSecondary =
        dark ? AppColors.textSecondary : const Color(0xFF6B6B6B);
    final accentBright =
        dark ? AppColors.accentBright : Color.lerp(accent, Colors.white, 0.25)!;
    final divider = dark ? const Color(0x1FFFFFFF) : const Color(0x14000000);

    final base = ThemeData(
        brightness: brightness, useMaterial3: true, fontFamily: 'Roboto');

    return base.copyWith(
      scaffoldBackgroundColor: background,
      colorScheme: base.colorScheme.copyWith(
        brightness: brightness,
        primary: accent,
        secondary: accentBright,
        surface: surface,
        error: AppColors.error,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: AppColors.textPrimary),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        thumbColor: accent,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: card,
        contentTextStyle: TextStyle(color: textPrimary, fontSize: 14),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      dialogTheme: DialogThemeData(backgroundColor: card),
      listTileTheme: ListTileThemeData(
        iconColor: textSecondary,
        titleTextStyle: TextStyle(
            color: textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
        subtitleTextStyle: TextStyle(color: textSecondary, fontSize: 13),
      ),
      dividerTheme: const DividerThemeData(color: Color(0x1FFFFFFF)),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStatePropertyAll(accent),
        trackColor: WidgetStatePropertyAll(accent.withValues(alpha: .3)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface.withValues(alpha: .92),
        indicatorColor: accent.withValues(alpha: .2),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: divider)),
      ),
    );
  }
}
