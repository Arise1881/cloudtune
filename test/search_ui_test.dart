import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cloudtune/core/models.dart';
import 'package:cloudtune/core/theme_state.dart';
import 'package:cloudtune/ui/search_ui.dart';

void _noop(int _) {}

void main() {
  group('SearchUi saf yardımcıları', () {
    test('süre rozeti biçimi', () {
      expect(SearchUi.durationLabel(null), '--:--');
      expect(SearchUi.durationLabel(const Duration(seconds: 34)), '00:34');
      expect(
        SearchUi.durationLabel(const Duration(hours: 1, seconds: 14)),
        '1:00:14',
      );
      expect(SearchUi.durationLabel(const Duration(minutes: 5, seconds: 3)),
          '05:03');
    });

    test('arama renkleri vurgu rengini izler', () {
      final previous = ThemeState.value;
      addTearDown(() => ThemeState.set(previous));
      ThemeState.set(Colors.red);
      expect(SearchUi.titleAccent, Colors.red);
      expect(SearchUi.activeAccent, Colors.red);
      ThemeState.set(Colors.orange);
      expect(SearchUi.titleAccent, Colors.orange);
      expect(SearchUi.activeAccent, Colors.orange);
    });

    test('sonuçlar korunur, yenilenen parçalar sona eklenir', () {
      const found = [
        Track(id: '1', title: 'Aratılan', artist: 'Blued'),
        Track(id: '2', title: 'Diğer sonuç', artist: 'Blued'),
      ];
      const extra = [
        Track(id: '3', title: 'Yeni', artist: 'Blued'),
        Track(id: '1', title: 'Tekrar', artist: 'Blued'),
      ];
      final merged = SearchUi.mergedResults(found, extra);
      expect(merged.map((t) => t.id), ['1', '2', '3']);
      expect(merged.first.title, 'Aratılan');
    });

    test('yenileme boşsa arama sonuçları değişmez', () {
      const found = [Track(id: '1', title: 'Aratılan', artist: 'Blued')];
      expect(SearchUi.mergedResults(found, const []), found);
    });

    test('sanatçı kartları tekil ve sıralı', () {
      final tracks = [
        const Track(id: '1', title: 'A', artist: 'Blued'),
        const Track(
          id: '2',
          title: 'B',
          artist: 'Blued',
          artistId: 'UC_blued',
        ),
        const Track(id: '3', title: 'C', artist: 'blued'),
        const Track(id: '4', title: 'D', artist: '   '),
        const Track(id: '5', title: 'E', artist: 'Başka'),
      ];
      final seeds = SearchUi.artistSeeds(tracks);
      expect(seeds.map((t) => t.id), ['1', '2', '5']);
    });
  });

  testWidgets('Ara başlığı açık mavi, alt nav Search aktif',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SearchTitle(),
              SearchNavBar(selected: SearchNavBar.search, onTap: _noop),
            ],
          ),
        ),
      ),
    );

    final title = tester.widget<Text>(find.text('Ara'));
    expect(title.style?.color, SearchUi.titleAccent);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });
}
