import 'package:http/http.dart' as http;

/// Web: tarayıcı proxy'yi kendisi yönetir, istemci doğrudan kullanılır.
http.Client ctProxiedClient(Uri? proxy) => http.Client();
