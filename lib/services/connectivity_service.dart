import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// İnternet bağlantısını izler; uygulama genelinde çevrimdışı/çevrimiçi
/// durumunu bildirir. İnternet kesildiğinde otomatik çevrimdışı moda geçiş
/// bu sınıfın sinyalleriyle yapılır.
///
/// Not: connectivity_plus yalnızca bağlantı *tipini* (wifi/hücresel) bildirir;
/// gerçek internet erişimi olmayabilir. Bu yüzden gerçek erişimi doğrulamak
/// için bir uzak sunucuya (Google DNS) gerçek bir TCP bağlantısı deniyoruz.
class ConnectivityService extends ChangeNotifier {
  ConnectivityService._() {
    _connectivity = Connectivity();
    _sub = _connectivity.onConnectivityChanged.listen(_onTypeChanged);
    _refresh();
  }

  static final ConnectivityService instance = ConnectivityService._();

  late final Connectivity _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  bool _hasNetworkType = true;
  bool _isOnline = true;
  bool _checking = false;
  bool _forceOffline = false;

  bool get _netOnline => !_forceOffline && _isOnline;
  bool get isOnline => _netOnline;
  bool get isOffline => !_netOnline;
  bool get forceOffline => _forceOffline;

  /// Kullanıcının manuel çevrimdışı tercihi (Ayarlar'da açılıp kapatılır).
  /// Gerçek bağlantıdan bağımsız olarak uygulamayı çevrimdışı moda alır.
  void setForceOffline(bool value) {
    if (_forceOffline == value) return;
    _forceOffline = value;
    debugPrint('forceOffline => ${value ? "açık" : "kapalı"}');
    notifyListeners();
  }

  /// Manuel çevrimdışı mod kapanınca / açılınca gerçek durumu yeniden yansıt.
  void retry() {
    if (!_hasNetworkType) {
      _setOnline(false);
      return;
    }
    _verifyReachability();
  }

  /// Gerçek bir internete erişim kontrolü başlatır (arka planda).
  void _onTypeChanged(List<ConnectivityResult> results) {
    final hasType = results.isNotEmpty && !results.contains(ConnectivityResult.none);
    _hasNetworkType = hasType;
    if (!hasType) {
      _setOnline(false);
    } else {
      // Bir ağ tipi var; gerçek erişimi doğrula.
      _verifyReachability();
    }
  }

  Future<void> _refresh() async {
    try {
      final results = await _connectivity.checkConnectivity();
      final hasType =
          results.isNotEmpty && !results.contains(ConnectivityResult.none);
      _hasNetworkType = hasType;
      if (!hasType) {
        _setOnline(false);
      } else {
        await _verifyReachability();
      }
    } catch (e) {
      debugPrint('connectivity_plus hatası: $e');
      // Platform desteği yoksa bile gerçek erişimi dene.
      _verifyReachability();
    }
  }

  /// Gerçek internet erişimini ölçer: Google DNS'e (8.8.8.8:53) TCP bağlanır.
  Future<void> _verifyReachability() async {
    if (_checking) return;
    _checking = true;
    try {
      final result = await InternetAddress.lookup('8.8.8.8')
          .timeout(const Duration(seconds: 5));
      final online = result.isNotEmpty && result.first.rawAddress.isNotEmpty;
      debugPrint('connectivity doğrulama: ${online ? "çevrimiçi" : "çevrimdışı"}');
      _setOnline(online);
    } catch (e) {
      debugPrint('connectivity doğrulama hatası: $e');
      _setOnline(false);
    } finally {
      _checking = false;
    }
  }

  void _setOnline(bool online) {
    if (_isOnline == online) return;
    _isOnline = online;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
