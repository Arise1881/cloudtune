import 'package:flutter/material.dart';

import '../constants.dart';

/// Çevrimdışıyken üstte görünen bilgi bandı.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.cardLight,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.cloud_off, size: 18, color: AppColors.accentBright),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  '${AppStrings.offlineTitle} — ${AppStrings.offlineMessage}',
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
