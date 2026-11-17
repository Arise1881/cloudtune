import 'dart:async';

import 'package:flutter/material.dart';

import '../core/local_sync_service.dart' if (dart.library.html) '../core/local_sync_web.dart';

/// Aynı Wi-Fi ağındaki CloudTune cihazlarıyla eşleştirme ve veri aktarımı.
/// Tüm trafik yerel ağ içinde kalır; internet sunucusu kullanılmaz.
class LocalSyncPage extends StatefulWidget {
  const LocalSyncPage({super.key});

  @override
  State<LocalSyncPage> createState() => _LocalSyncPageState();
}

class _LocalSyncPageState extends State<LocalSyncPage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _pin = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final sync = LocalSyncService.instance;
    _name.text = sync.deviceName;
    unawaited(sync.init());
  }

  @override
  void dispose() {
    _name.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _setEnabled(bool value) async {
    final sync = LocalSyncService.instance;
    await sync.setEnabled(value);
    if (value) {
      await sync.start();
    } else {
      await sync.stop();
    }
  }

  Future<void> _pair(DiscoveredDevice device) async {
    if (_busy) return;
    setState(() => _busy = true);
    await LocalSyncService.instance.pair(device, _pin.text.trim());
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _syncNow() async {
    if (_busy) return;
    setState(() => _busy = true);
    await LocalSyncService.instance.syncNow();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final sync = LocalSyncService.instance;

    return Scaffold(
      appBar: AppBar(title: const Text('Yerel eşitleme')),
      body: ListenableBuilder(
        listenable: sync,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.wifi_tethering),
              title: const Text('Yerel eşitlemeyi aç'),
              subtitle: Text(sync.statusLabel),
              value: sync.enabled,
              onChanged: sync.running ? null : _setEnabled,
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Aynı ağdaki diğer CloudTune cihazları bulunur. PIN ile '
                'eşleştirildikten sonra seçilen veriler doğrudan cihazlar '
                'arasında aktarılır; sunucu kullanılmaz.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            if (sync.running) ...[
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'EŞLEŞTİRME KODU',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                          color: Colors.white54,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        sync.pinLabel,
                        style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 6,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Bu kodu diğer cihazda girin. Kod birkaç dakika geçerlidir.',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            ListTile(
              leading: const Icon(Icons.devices),
              title: const Text('Cihaz adı'),
              subtitle: const Text('Ağda görünecek ad.'),
              trailing: SizedBox(
                width: 170,
                child: TextField(
                  controller: _name,
                  textAlign: TextAlign.end,
                  onSubmitted: (value) =>
                      LocalSyncService.instance.setDeviceName(value),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.search),
              title: const Text('Cihazları tara'),
              subtitle: Text(
                sync.devices.isEmpty
                    ? 'Henüz cihaz bulunamadı.'
                    : '${sync.devices.length} cihaz görüldü.',
              ),
              onTap: sync.running
                  ? () => LocalSyncService.instance.discoverOnce()
                  : null,
            ),
            for (final device in sync.devices)
              ListTile(
                leading: const Icon(Icons.phone_android),
                title: Text(device.name),
                subtitle: Text('${device.address}:${device.port}'),
                trailing: TextButton(
                  onPressed: _busy ? null : () => _pair(device),
                  child: const Text('Eşleştir'),
                ),
              ),
            if (sync.running)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: TextField(
                  controller: _pin,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(
                    labelText: 'Diğer cihazın kodu',
                    hintText: '123456',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            const Divider(),

            const _Title('EŞLEŞEN CİHAZLAR'),
            if (sync.pairedIds.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  'Eşleşen cihaz yok.',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
            for (final id in sync.pairedIds)
              ListTile(
                leading: const Icon(Icons.link),
                title: Text(id),
                trailing: IconButton(
                  tooltip: 'Unut',
                  icon: const Icon(Icons.link_off),
                  onPressed: () => sync.forget(id),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('Tümünü unut'),
              onTap: sync.pairedIds.isEmpty ? null : sync.forgetAll,
            ),
            const Divider(),

            const _Title('AKTARILACAK VERİLER'),
            for (final category in const <String>[
              'playlists',
              'history',
              'liked',
              'downloads',
              'settings',
            ])
              SwitchListTile(
                dense: true,
                title: Text(_categoryLabel(category)),
                value: sync.categories.contains(category),
                onChanged: (_) => sync.toggleCategory(category),
              ),
            SwitchListTile(
              secondary: const Icon(Icons.autorenew),
              title: const Text('Otomatik eşitle'),
              subtitle: const Text('Cihaz göründüğünde veriler aktarılır.'),
              value: sync.autoSync,
              onChanged: (value) => sync.setAutoSync(value),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FilledButton.icon(
                onPressed: _busy || sync.pairedIds.isEmpty ? null : _syncNow,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: const Text('Şimdi eşitle'),
              ),
            ),
            if (sync.lastSyncedAt != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Son eşitleme: ${sync.lastSyncedAt}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _categoryLabel(String category) => switch (category) {
      'playlists' => 'Çalma listeleri',
      'history' => 'Dinleme geçmişi',
      'liked' => 'Beğenilenler',
      'downloads' => 'İndirilenler (yalnızca bilgi)',
      'settings' => 'Uygulama ayarları',
      _ => category,
    };

class _Title extends StatelessWidget {
  const _Title(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
          color: Colors.white54,
        ),
      ),
    );
  }
}
