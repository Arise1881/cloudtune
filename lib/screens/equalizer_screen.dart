import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../services/equalizer_service.dart';

/// Parametrik ekolayzer ekranı (5 bant).
class EqualizerScreen extends StatelessWidget {
  const EqualizerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final eq = context.watch<EqualizerService>();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        title: const Text('Ekolayzer',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Aç/kapa
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: eq.enabled,
            onChanged: (_) => eq.toggleEnabled(),
            title: const Text('Ekolayzer',
                style: TextStyle(
                    color: AppColors.textPrimary, fontWeight: FontWeight.w700)),
            subtitle: const Text('Ses tonunu kişiselleştir',
                style: TextStyle(color: AppColors.textSecondary)),
            activeTrackColor: AppColors.accent,
            activeThumbColor: Colors.black,
          ),
          const SizedBox(height: 20),

          if (eq.enabled) ...[
            // Hazır ayarlar
            const Text('Hazır Ayarlar',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: EqPreset.values.map((p) {
                final selected = eq.preset == p;
                return ChoiceChip(
                  label: Text(eq.presetLabelFor(p),
                      style: TextStyle(
                          fontSize: 13,
                          color: selected ? Colors.black : AppColors.textPrimary)),
                  selected: selected,
                  onSelected: (_) => eq.setPreset(p),
                  selectedColor: AppColors.accent,
                  backgroundColor: AppColors.card,
                  checkmarkColor: Colors.black,
                  side: BorderSide.none,
                );
              }).toList(),
            ),
            const SizedBox(height: 28),

            // Bant slayderları
            const Text('Özel Bantlar',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SizedBox(
              height: 220,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: List.generate(
                  EqualizerService.bandCount,
                  (i) => Expanded(
                    child: Column(
                      children: [
                        Expanded(
                          child: RotatedBox(
                            quarterTurns: 3,
                            child: Slider(
                              value: eq.bands[i],
                              min: EqualizerService.minDb,
                              max: EqualizerService.maxDb,
                              activeColor: AppColors.accent,
                              inactiveColor: AppColors.card,
                              onChanged: (v) => eq.setBand(i, v),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(_bandLabel(i),
                            style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _GainBar(bands: eq.bands),
          ] else
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(
                child: Text('Ekolayzer kapalı',
                    style: TextStyle(color: AppColors.textSecondary)),
              ),
            ),
        ],
      ),
    );
  }

  String _bandLabel(int i) => EqualizerService.bandFrequencies[i] >= 1000
      ? '${(EqualizerService.bandFrequencies[i] / 1000).round()}k'
      : '${EqualizerService.bandFrequencies[i].round()}';
}

class _GainBar extends StatelessWidget {
  const _GainBar({required this.bands});
  final List<double> bands;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: List.generate(bands.length, (i) {
          return Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 4),
                Text('${bands[i] >= 0 ? '+' : ''}${bands[i].toStringAsFixed(1)}',
                    style: TextStyle(
                        fontSize: 10,
                        color: bands[i] >= 0
                            ? AppColors.accent
                            : AppColors.error)),
                const SizedBox(height: 2),
                Text('dB',
                    style: TextStyle(
                        fontSize: 9,
                        color: AppColors.textSecondary.withValues(alpha: .7))),
              ],
            ),
          );
        }),
      ),
    );
  }
}
