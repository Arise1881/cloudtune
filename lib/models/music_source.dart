/// Melody'nin müzik sağlayıcı tipi.
///
/// YouTube varsayılan değildir: [MusicSourceType] `audius` varsayılanıyla
/// uygulama yasal/ücretsiz katalogdan başlar. YouTube yalnızca kullanıcının
/// kendi seçimiyle (kişisel kullanım) açılır — dağıtık uygulamalarda içerik
/// telifi ve akış kısıtlama riski taşıdığı için varsayılan değildir.
enum MusicSourceType {
  /// Audius — merkeziyetsiz, açık, ücretsiz mp3 kataloğu (API anahtarsız).
  audius('Audius', 'audius', 'Merkeziyetsiz ücretsiz müzik kataloğu'),

  /// Internet Archive — kamu malı / CC lisanslı ses koleksiyonu.
  internetArchive('Internet Archive', 'archive', 'Kamu malı ve CC lisanslı arşiv'),

  /// YouTube / YouTube Music — kişisel kullanım seçeneği (varsayılan değil).
  youtube('YouTube', 'youtube', 'Kişisel kullanım (içerik sahibi YouTube)');

  final String label;
  final String code;
  final String description;

  const MusicSourceType(this.label, this.code, this.description);

  /// Esnek geçici URL çözümlemesine ihtiyaç duyar mı (yalnızca YouTube gerektirir).
  bool get needsProxiedStreams => this == MusicSourceType.youtube;

  /// Bu sağlayıcı şarkı sözü destekliyor mu (yalnız YouTube altyazı sunar).
  bool get supportsLyrics => this == MusicSourceType.youtube;

  static MusicSourceType fromCode(String? code) {
    for (final s in MusicSourceType.values) {
      if (s.code == code) return s;
    }
    return MusicSourceType.audius;
  }

  static String? toCode(MusicSourceType t) => t.code;
}
