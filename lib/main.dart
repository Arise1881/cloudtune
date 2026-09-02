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
      androidNotificationOngoing: true,
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

  // Güncelleme kontrolü (uygulamayı bloklamaz; arka planda çalışır)
  try {
    await UpdateService.instance.init();
  } catch (e) {
    debugPrint('Güncelleme kontrolü başlatma uyarısı: $e');
  }

  // Ekolayzer (YouTube Music benzeri ses ayarı)
  try {
    await EqualizerService.instance.init();
  } catch (e) {
    debugPrint('Ekolayzer başlatma uyarısı: $e');
  }

  runApp(const MelodyApp());
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
      ],
      child: MaterialApp(
        title: AppStrings.appName,
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(),
        routes: {
          '/settings': (_) => const SettingsScreen(),
        },
        home: const RootScreen(),
      ),
    );
  }

  ThemeData _buildTheme() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: base.colorScheme.copyWith(
        brightness: Brightness.dark,
        primary: AppColors.accent,
        secondary: AppColors.accentBright,
        surface: AppColors.surface,
        error: AppColors.error,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: AppColors.textPrimary),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: AppColors.textPrimary,
        thumbColor: AppColors.textPrimary,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.cardLight,
        contentTextStyle:
            const TextStyle(color: AppColors.textPrimary, fontSize: 14),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      dialogTheme: DialogThemeData(backgroundColor: AppColors.card),
      listTileTheme: ListTileThemeData(
        iconColor: AppColors.textSecondary,
        titleTextStyle: const TextStyle(
            color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
        subtitleTextStyle:
            const TextStyle(color: AppColors.textSecondary, fontSize: 13),
      ),
      dividerTheme: const DividerThemeData(color: Color(0x1FFFFFFF)),
    );
  }
}
