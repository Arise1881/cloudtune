import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../services/connectivity_service.dart';
import '../widgets/mini_player.dart';
import '../widgets/offline_banner.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'search_screen.dart';

/// Ana iskelet: alt navigasyon barı KALDIRILDI.
/// Sekme geçişi yatay kaydırmayla yapılır (sol→sağ önceki, sağ→sol sonraki).
/// Mini oynatıcı ve çevrimdışı bandı korunur.
class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => RootScreenState();
}

class RootScreenState extends State<RootScreen> {
  int _tab = 0;
  final _homeKey = GlobalKey<HomeScreenState>();

  /// Dışarıdan sekme geçişi (ör. "İndirilenler" kısayolu → Kitaplık).
  void goTab(int index) {
    if (index < 0 || index > 2) return;
    setState(() => _tab = index);
  }

  @override
  Widget build(BuildContext context) {
    final offline = context.watch<ConnectivityService>().isOffline;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          if (offline) const OfflineBanner(),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragEnd: (d) {
                final v = d.primaryVelocity ?? 0;
                if (v < -120 && _tab < 2) setState(() => _tab++);
                if (v > 120 && _tab > 0) setState(() => _tab--);
              },
              child: IndexedStack(
                index: _tab,
                children: [
                  HomeScreen(key: _homeKey),
                  const SearchScreen(),
                  const LibraryScreen(),
                ],
              ),
            ),
          ),
          const MiniPlayer(),
        ],
      ),
    );
  }
}
