import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../services/update_service.dart';

/// Ana sayfada güncelleme mevcut olduğunda görünen şerit.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final update = context.watch<UpdateService>();
    if (!update.updateAvailable) return const SizedBox.shrink();

    return Material(
      color: AppColors.accentBright,
      child: InkWell(
        onTap: () => _showUpdateDialog(context, update),
        child: SafeArea(
          bottom: false,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.system_update_alt,
                    color: Colors.black, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Melody ${update.latestVersion} yayınlandı',
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        update.prepared
                            ? 'Kuruluma hazır — kurmak için dokun'
                            : update.downloading
                                ? 'İndiriliyor… %${(update.downloadProgress * 100).toInt()}'
                                : 'Güncellemek için dokun',
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.black),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showUpdateDialog(
      BuildContext context, UpdateService update) async {
    final msg = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Güncelleme mevcut',
            style: TextStyle(color: AppColors.textPrimary)),
        content: Text(
          'Melody ${update.latestVersion} sürümü yayınlandı.\n\nGüncellemek istiyor musun?',
          style: const TextStyle(color: AppColors.textSecondary, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'dismiss'),
            child: const Text('Daha sonra'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'update'),
            child: Text(
              'Güncelle',
              style: TextStyle(
                  color: AppColors.accentBright, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    ) ?? 'dismiss';

    if (msg != 'update') return;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(await update.applyUpdate())),
    );
  }
}
