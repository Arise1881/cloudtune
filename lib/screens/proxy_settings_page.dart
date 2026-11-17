import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/proxy_service.dart';

/// Kullanıcı tanımlı proxy sunucularının yönetimi.
/// Bağlantı başarısızlıkları sessizce ele alınır; ayrıntı gösterilmez.
class ProxySettingsPage extends StatefulWidget {
  const ProxySettingsPage({super.key});

  @override
  State<ProxySettingsPage> createState() => _ProxySettingsPageState();
}

class _ProxySettingsPageState extends State<ProxySettingsPage> {
  final TextEditingController _input = TextEditingController();
  final Set<int> _testing = <int>{};

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final value = _input.text.trim();
    if (value.isEmpty) return;
    await ProxyService.instance.addServer(value);
    _input.clear();
  }

  Future<void> _test(int index, String address) async {
    if (_testing.contains(index)) return;
    setState(() => _testing.add(index));
    await ProxyService.instance.testServer(address);
    if (mounted) setState(() => _testing.remove(index));
  }

  @override
  Widget build(BuildContext context) {
    final proxy = ProxyService.instance;

    return Scaffold(
      appBar: AppBar(title: const Text('Proxy ayarları')),
      body: ListenableBuilder(
        listenable: proxy,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.public),
              title: const Text('Proxy kullan'),
              subtitle: Text(proxy.statusLabel),
              value: proxy.enabled,
              onChanged: (value) => proxy.setEnabled(value),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8, bottom: 12),
              child: Text(
                'Proxy yalnızca ses akışı adresinin çözümlenmesinde kullanılır. '
                'Sunucu ekleyip test ettikten sonra kapatıp açmanız gerekmez.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Sunucu adresi',
                      hintText: '1.2.3.4:8080',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _add,
                  child: const Text('Ekle'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              'SUNUCULAR · ${proxy.servers.length}/${ProxyService.maxServers}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
                color: Colors.white54,
              ),
            ),
            const SizedBox(height: 4),
            RadioGroup<int>(
              groupValue: proxy.selectedIndex,
              onChanged: (value) => proxy.setSelected(value ?? -1),
              child: Column(
                children: [
                  const RadioListTile<int>(
                    contentPadding: EdgeInsets.zero,
                    value: -1,
                    title: Text('Otomatik sıralı kullanım'),
                    subtitle: Text('Sunucular sırayla denenir.'),
                  ),
                  for (var i = 0; i < proxy.servers.length; i++)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Radio<int>(value: i),
                      title: Text(proxy.servers[i]),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _testing.contains(i)
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : IconButton(
                                  tooltip: 'Sına',
                                  icon: const Icon(Icons.network_check),
                                  onPressed: () => _test(i, proxy.servers[i]),
                                ),
                          IconButton(
                            tooltip: 'Kaldır',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => proxy.removeServer(i),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (proxy.lastUsed != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.check_circle_outline),
                title: const Text('Son çalışan sunucu'),
                subtitle: Text(proxy.lastUsed!),
                trailing: IconButton(
                  tooltip: 'Kopyala',
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: proxy.lastUsed!));
                  },
                ),
              ),
            const Divider(),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.info_outline),
              title: Text('Gizlilik'),
              subtitle: Text(
                'Sunucu listesi yalnızca bu cihazda saklanır. Bağlantı '
                'bilgisi veya hata mesajı arayüzde gösterilmez.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
