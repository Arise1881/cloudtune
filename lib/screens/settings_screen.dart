import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../models/song.dart';
import '../services/connectivity_service.dart';
import '../services/download_manager.dart';
import '../services/library_store.dart';
import '../services/music_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'library_screen.dart';
import 'playlist_screen.dart';
import 'now_playing_screen.dart';

/// Ayarlar ekranı: tema, kalite, ekolayzer ve diğer ayarlar.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final quality = player.currentQuality;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ayarlar'),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle('Genel'),
            const SizedBox(height: 8),
            _buildToggleSwitch(
              context: context,
              title: 'Karanlık Mod',
              subtitle: 'Uygulama renk şemasını değiştir',
              value: isDark,
              onChanged: (value) {
                final ThemeMode mode = value ? ThemeMode.dark : ThemeMode.light;
                final ThemeProvider provider = context.read<ThemeProvider>();
                provider.setThemeMode(mode);
              },
            ),
            const SizedBox(height: 16),
            _buildSectionTitle('Ses Kalitesi'),
            const SizedBox(height: 8),
            _buildQualityDropdown(context: context, currentQuality: quality),
            const SizedBox(height: 16),
            _buildSectionTitle('Ekolayzer'),
            const SizedBox(height: 8),
            _buildEqualityPresetDropdown(context: context),
            const SizedBox(height: 16),
            _buildSectionTitle('Diğer'),
            const SizedBox(height: 8),
            _buildToggleSwitch(
              context: context,
              title: 'Emoji Desteği',
              subtitle: 'Emoji'ler'la şarkı isimlerini göster',
              value: true,
              onChanged: (_) {},
            ),
            const SizedBox(height: 16),
            _buildToggleSwitch(
              context: context,
              title: 'Çevrimdışı Mod',
              subtitle: 'Çevrimdışı modu etkinleştir/kapat',
              value: context.watch<ConnectivityService>().isOffline,
              onChanged: (value) {
                final connectivity = context.read<ConnectivityService>();
                connectivity.setOfflineMode(value);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Text(
        title,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildToggleSwitch({
    required BuildContext context,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      title: Text(
        title,
        style: const TextStyle(color: AppColors.textPrimary),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: AppColors.textSecondary),
      ),
      value: value,
      onChanged: onChanged,
      activeColor: AppColors.accent,
    );
  }

  Widget _buildQualityDropdown({
    required BuildContext context,
    required AudioQuality currentQuality,
  }) {
    return DropdownButton<AudioQuality>(
      value: currentQuality,
      icon: const Icon(Icons.arrow_drop_down),
      elevation: 16,
      style: const TextStyle(color: AppColors.textPrimary),
      underline: Container(
        height: 2,
        color: AppColors.accent,
      ),
      onChanged: (AudioQuality? newQuality) {
        if (newQuality != null) {
          context.read<PlayerService>().setQuality(newQuality);
        }
      },
      items: AudioQuality.values.map((AudioQuality quality) {
        return DropdownMenuItem<AudioQuality>(
          value: quality,
          child: Text(_qualityLabel(quality)),
        );
      }).toList(),
    );
  }

  Widget _buildEqualityPresetDropdown({
    required BuildContext context,
  }) {
    final player = context.watch<PlayerService>();
    final preset = player.presetName;

    return DropdownButton<String>(
      value: preset,
      icon: const Icon(Icons.arrow_drop_down),
      elevation: 16,
      style: const TextStyle(color: AppColors.textPrimary),
      underline: Container(
        height: 2,
        color: AppColors.accent,
      ),
      onChanged: (String? newPreset) {
        if (newPreset != null) {
          player.setPreset(newPreset);
        }
      },
      items: ['flat', 'pop', 'rock', 'jazz', 'classical', 'bass boost', 'vocal'].map((String preset) {
        return DropdownMenuItem<String>(
          value: preset,
          child: Text(preset[0].toUpperCase() + preset.substring(1)),
        );
      }).toList(),
    );
  }
}