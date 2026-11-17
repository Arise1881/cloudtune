import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Masaüstü/mobil: verilen proxy üzerinden çalışan istemci.
http.Client ctProxiedClient(Uri? proxy) {
  final hc = HttpClient();
  if (proxy != null) {
    hc.findProxy = (_) => 'PROXY ${proxy.host}:${proxy.port}';
  }
  return IOClient(hc);
}
