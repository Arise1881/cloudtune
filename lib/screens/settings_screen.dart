import 'package:flutter/material.dart';

import '../core/theme_state.dart';

/// CloudTune ayar ekrani. Icerisinden kullanici:
/// - Ana sayfaya donme butonu
/// - Vurgu rengi secenekleri
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const List<Color> accentOptions = [
    Color(0xFF1DB954), // Yesil (varsayilan)
    Color(0xFF1ED760), // Acik Yesil
    Color(0xFF1AA34A), // Koyu Yesil
    Color(0xFF2196F3), // Mavi
    Color(0xFFFF9800), // Turuncu
    Color(0xFFE91E63), // Pembe
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ayarlar')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.arrow_back),
            title: const Text('Ana Sayfaya Dön'),
            onTap: () => Navigator.of(context).popUntil((route) => route.isFirst),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Vurgu Rengi'),
          ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final c in accentOptions)
                ValueListenableBuilder<Color>(
                  valueListenable: ThemeState.accent,
                  builder: (context, value, _) {
                    final selected = value == c;
                    return OutlinedButton.icon(
                      onPressed: () => ThemeState.set(c),
                      icon: CircleAvatar(
                        radius: 14,
                        backgroundColor: c,
                        child: selected
                            ? const Icon(Icons.check, size: 16, color: Colors.white)
                            : null,
                      ),
                      label: Text(selected ? 'Secildi' : 'Secenek'),
                    );
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}
