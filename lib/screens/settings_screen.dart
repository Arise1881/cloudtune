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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ayarlar'),
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.textPrimary,
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
              onChanged: (_) {},
            ),
            const SizedBox(height: 16),
            _buildSectionTitle('Ses Kalitesi'),
            const SizedBox(height: 8),
            _buildQualityDropdown(context: context),
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
              subtitle: 'Emoji ile şarkı isimlerini göster',
              value: true,
              onChanged: (_) {},
            ),
            const SizedBox(height: 16),
            _buildToggleSwitch(
              context: context,
              title: 'Çevrimdışı Mod',
              subtitle: 'Çevrimdışı modu etkinleştir/kapat',
              value: context.watch<ConnectivityService>().isOffline,
              onChanged: (_) {},
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
      activeThumbColor: AppColors.accent,
    );
  }

  Widget _buildQualityDropdown({
    required BuildContext context,
  }) {
    return DropdownButton<String>(
      value: 'Otomatik',
      icon: const Icon(Icons.arrow_drop_down),
      elevation: 16,
      style: const TextStyle(color: AppColors.textPrimary),
      underline: Container(
        height: 2,
        color: AppColors.accent,
      ),
      onChanged: (_) {},
      items: ['Otomatik', 'Yüksek (320kbps)', 'Orta (128kbps)', 'Düşük (48kbps)'].map((String quality) {
        return DropdownMenuItem<String>(
          value: quality,
          child: Text(quality),
        );
      }).toList(),
    );
  }

  Widget _buildEqualityPresetDropdown({
    required BuildContext context,
  }) {
    return DropdownButton<String>(
      value: 'flat',
      icon: const Icon(Icons.arrow_drop_down),
      elevation: 16,
      style: const TextStyle(color: AppColors.textPrimary),
      underline: Container(
        height: 2,
        color: AppColors.accent,
      ),
      onChanged: (_) {},
      items: ['flat', 'pop', 'rock', 'jazz', 'classical', 'bass boost', 'vocal'].map((String preset) {
        return DropdownMenuItem<String>(
          value: preset,
          child: Text(preset[0].toUpperCase() + preset.substring(1)),
        );
      }).toList(),
    );
  }
}