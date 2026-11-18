// Çalma listesi mantığı için SAF testler: shared_preferences, Library.instance,
// Flutter binding veya platform kanalı KULLANILMAZ. Gerçek model yazıldığında
// bu saf fonksiyonlar modelin statik metotlarına birebir taşınabilir.

import 'package:flutter_test/flutter_test.dart';

class TestTrack {
  const TestTrack(this.id, [this.title = '']);

  final String id;
  final String title;
}

String sanitizeName(String raw) => raw.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Türkçe karakterleri ASCII'ye indirgeyen, sıralamadan bağımsız kararlı id.
String playlistId(String name) {
  const turkish = <String, String>{
    'İ': 'i',
    'I': 'i',
    'ı': 'i',
    'Ş': 's',
    'ş': 's',
    'Ğ': 'g',
    'ğ': 'g',
    'Ü': 'u',
    'ü': 'u',
    'Ö': 'o',
    'ö': 'o',
    'Ç': 'c',
    'ç': 'c',
  };
  final clean = sanitizeName(name);
  final buffer = StringBuffer();
  for (final codeUnit in clean.runes) {
    final char = String.fromCharCode(codeUnit);
    final mapped = (turkish[char] ?? char).toLowerCase();
    if (RegExp(r'[a-z0-9]').hasMatch(mapped)) {
      buffer.write(mapped);
    } else {
      buffer.write('_');
    }
  }
  final slug = buffer
      .toString()
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  return 'pl_${slug.isEmpty ? 'untitled' : slug}';
}

/// ReorderableListView sözleşmesi: aşağı taşımada hedef bir azaltılır.
List<T> reorder<T>(List<T> items, int from, int to) {
  if (from == to ||
      from < 0 ||
      to < 0 ||
      from >= items.length ||
      to >= items.length) {
    return List<T>.of(items);
  }
  final result = List<T>.of(items);
  final moved = result.removeAt(from);
  final insertAt = to > from ? to - 1 : to;
  result.insert(insertAt, moved);
  return List<T>.unmodifiable(result);
}

/// Eski (v1: string listesi), orta (v2: map listesi) ve yeni (v3: trackIds)
/// kayıt formatlarını tek şemaya çeker.
Map<String, dynamic> migratePlaylist(Map<String, dynamic> raw) {
  final name = sanitizeName(
    (raw['title'] ?? raw['name'] ?? '').toString(),
  );
  final title = name.isEmpty ? 'İsimsiz liste' : name;

  final source = raw['trackIds'] ?? raw['tracks'] ?? raw['songs'] ?? const <dynamic>[];
  final ids = <String>[];
  if (source is List) {
    for (final entry in source) {
      String? id;
      if (entry is String) {
        id = entry;
      } else if (entry is Map) {
        id = (entry['id'] ?? entry['videoId'] ?? '').toString();
      }
      if (id != null && id.isNotEmpty && !ids.contains(id)) ids.add(id);
    }
  }

  final storedId = raw['id']?.toString();
  return <String, dynamic>{
    'id': (storedId == null || storedId.isEmpty) ? playlistId(title) : storedId,
    'title': title,
    'trackIds': List<String>.unmodifiable(ids),
  };
}

List<Map<String, dynamic>> migrateAll(List<dynamic> raw) {
  return raw
      .whereType<Map>()
      .map((entry) => migratePlaylist(Map<String, dynamic>.from(entry)))
      .toList();
}

Map<String, dynamic> moveTrack(
  Map<String, dynamic> playlist,
  int from,
  int to,
) {
  final ids = List<String>.from(playlist['trackIds'] as List<String>);
  return <String, dynamic>{
    ...playlist,
    'trackIds': reorder(ids, from, to),
  };
}

void main() {
  group('kararlı id', () {
    test('Türkçe karakterler ASCII slug olur', () {
      expect(playlistId('Türkçe Pop 2026'), 'pl_turkce_pop_2026');
      expect(playlistId('  Şarkı   Listesi  '), 'pl_sarki_listesi');
      expect(playlistId('İstanbul / Özgün'), 'pl_istanbul_ozgun');
    });

    test('id doğru ve boş isimde güvenli', () {
      expect(playlistId('Lofi'), playlistId('Lofi'));
      expect(playlistId('   '), 'pl_untitled');
      expect(playlistId('!!!'), 'pl_untitled');
    });
  });

  group('reorder', () {
    final tracks = List<TestTrack>.generate(
      4,
      (i) => TestTrack('t$i'),
      growable: false,
    );

    test('aşağı taşıma: hedef bir azaltılır', () {
      expect(
        reorder(tracks, 0, 3).map((t) => t.id).toList(),
        <String>['t1', 't2', 't0', 't3'],
      );
    });

    test('yukarı taşıma: doğrudan hedefe eklenir', () {
      expect(
        reorder(tracks, 3, 0).map((t) => t.id).toList(),
        <String>['t3', 't0', 't1', 't2'],
      );
    });

    test('aynı indis ve sınır dışı değerler liste olduğu gibi döndürür', () {
      expect(reorder(tracks, 1, 1), tracks);
      expect(reorder(tracks, -1, 2), tracks);
      expect(reorder(tracks, 0, 99), tracks);
      expect(reorder(const <String>[], 0, 1), isEmpty);
    });

    test('orijinal liste mutate edilmez', () {
      final result = reorder(tracks, 0, 2);
      expect(tracks.first.id, 't0');
      expect(result.first.id, 't1');
    });
  });

  group('migrasyon', () {
    test('v1: string listesi, tekrar eden ve boş id ayıklanır', () {
      final result = migratePlaylist(<String, dynamic>{
        'name': 'Eski Liste',
        'tracks': <dynamic>['a', '', 'b', 'a', 'c'],
      });
      expect(result['id'], 'pl_eski_liste');
      expect(result['title'], 'Eski Liste');
      expect(result['trackIds'], <String>['a', 'b', 'c']);
    });

    test('v2: map listesi videoId alanını okur', () {
      final result = migratePlaylist(<String, dynamic>{
        'title': 'Yeni Liste',
        'songs': <dynamic>[
          <String, dynamic>{'videoId': 'x', 'title': 'X'},
          <String, dynamic>{'id': 'y', 'title': 'Y'},
          <String, dynamic>{'title': 'idsiz'},
        ],
      });
      expect(result['trackIds'], <String>['x', 'y']);
      expect(result['id'], 'pl_yeni_liste');
    });

    test('v3: kayıtlı id korunur', () {
      final result = migratePlaylist(<String, dynamic>{
        'id': 'pl_ozel',
        'title': 'Özel',
        'trackIds': <String>['k1', 'k2'],
      });
      expect(result['id'], 'pl_ozel');
      expect(result['trackIds'], <String>['k1', 'k2']);
    });

    test('boş/bozuk kayıtlar güvenli varsayılana düşer', () {
      final result = migratePlaylist(<String, dynamic>{});
      expect(result['title'], 'İsimsiz liste');
      expect(result['id'], 'pl_isimsiz_liste');
      expect(result['trackIds'], isEmpty);

      final all = migrateAll(<dynamic>[
        <String, dynamic>{'name': 'A', 'tracks': <String>['1']},
        'bozuk kayıt',
        42,
      ]);
      expect(all, hasLength(1));
      expect(all.first['title'], 'A');
    });
  });

  group('sıralama + kimlik birlikte', () {
    test('parça taşıma id ve başlığı değiştirmez', () {
      final playlist = migratePlaylist(<String, dynamic>{
        'title': 'Karışık',
        'trackIds': <String>['a', 'b', 'c'],
      });
      final moved = moveTrack(playlist, 0, 2);
      expect(moved['id'], playlist['id']);
      expect(moved['title'], 'Karışık');
      expect(moved['trackIds'], <String>['b', 'a', 'c']);
    });
  });
}
