import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../services/connectivity_service.dart';
import '../widgets/mini_player.dart';
import '../widgets/offline_banner.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'search_screen.dart';

/// Ana iskelet: alt navigasyon + mini oynatıcı + çevrimdışı bandı.
class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _tab = 0;
  final _homeKey = GlobalKey<HomeScreenState>();

  @override
  Widget build(BuildContext context) {
    final offline = context.watch<ConnectivityService>().isOffline;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          if (offline) const OfflineBanner(),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                HomeScreen(key: _homeKey),
                const SearchScreen(),
                const LibraryScreen(),
              ],
            ),
          ),
          const MiniPlayer(),
        ],
      ),
      bottomNavigationBar: _BottomNav(
        current: _tab,
        onChanged: (i) {
          if (i == 0 && _tab == 0) {
            // Home tab re-tapped -> refresh
            _homeKey.currentState?.refreshNow();
          } else {
            setState(() => _tab = i);
          }
        },
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.current, required this.onChanged});

  final int current;
  final ValueChanged<int> onChanged;

  static const _items = [
    (icon: Icons.home_outlined, activeIcon: Icons.home, label: 'Ana Sayfa'),
    (icon: Icons.search_outlined, activeIcon: Icons.search, label: 'Ara'),
    (icon: Icons.library_music_outlined, activeIcon: Icons.library_music, label: 'Kitaplığın'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.black,
        border: Border(top: BorderSide(color: Color(0xFF2A2A2A))),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: List.generate(_items.length, (i) {
            final item = _items[i];
            final selected = i == current;
            return Expanded(
              child: InkWell(
                onTap: () => onChanged(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        selected ? item.activeIcon : item.icon,
                        color: selected ? AppColors.textPrimary : AppColors.textSecondary,
                        size: 24,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: selected ? AppColors.textPrimary : AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
