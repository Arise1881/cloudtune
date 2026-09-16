import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_background/just_audio_background.dart';
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
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // Arka planda çalma + kilit ekranı bildirimi.
  // Başarısız olsa bile uygulamanın açılması engellenmez.
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.melody.app.playback',
      androidNotificationChannelName: 'Melody Müzik Çalar',
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: true,
      preloadArtwork: true,
    );
  } catch (e) {
    debugPrint('JustAudioBackground init uyarısı: $e');
  }

  final library = LibraryStore.instance;
  try {
    await library.init();
  } catch (e) {
    debugPrint('Kitaplık yükleme uyarısı: $e');
  }

  // Oynatıcıda saklanan ses kalitesi tercihi (YouTube Music benzeri)
  try {
    await PlayerService.instance.loadQualityPref();
  } catch (e) {
    debugPrint('Ses kalitesi tercihi yükleme uyarısı: $e');
  }

  // Ekolayzer (YouTube Music benzeri ses ayarı)
  try {
    await EqualizerService.instance.init();
  } catch (e) {
    debugPrint('Ekolayzer başlatma uyarısı: $e');
  }

  // Güncelleme kontrolü (ilk kareyi bloklamaz; arka planda çalışır)
  UpdateService.instance.init();

  // Tema tercihi (açık/koyu + vurgu rengi)
  try {
    await ThemeService.instance.init();
  } catch (e) {
    debugPrint('Tema başlatma uyarısı: $e');
  }

  // Son çalman oturumu geri yükle (kuyruk + konum)
  try {
    await PlayerService.instance.restoreSession();
  } catch (e) {
    debugPrint('Oturum geri yükleme uyarısı: $e');
  }

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };

  await runZonedGuarded(() async {
    runApp(const MelodyApp());
  }, (error, stack) {
    debugPrint('Yakalanmayan hata: $error\n$stack');
  });
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
