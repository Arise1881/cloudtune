import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/app_palette.dart';
import '../core/player_controller.dart';
import '../core/radio_service.dart';
import '../l10n/app_strings.dart';

/// radio-browser.info kataloğundaki Türkiye radyoları.
///
/// İstasyonlar doğrudan akış URL'siyle `PlayerController` üzerinden çalınır;
/// YouTube çözümlemesi veya "sonsuz radyo" öneri modu kullanılmaz.
class RadioPage extends StatefulWidget {
  const RadioPage({super.key});

  @override
  State<RadioPage> createState() => _RadioPageState();
}

class _RadioPageState extends State<RadioPage> {
  final TextEditingController _search = TextEditingController();
  final TurkishRadioService _service = TurkishRadioService.instance;
  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_service.load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() => _service.load(refresh: true);

  Widget get _logoPlaceholder => Container(
        color: AppPalette.cardRaised,
        alignment: Alignment.center,
        child: const Icon(Icons.radio, size: 22),
      );

  void _play(List<RadioStation> list, int index) {
    final station = list[index];
    PlayerController.instance.playQueue(
      list.map((item) => item.toTrack()).toList(growable: false),
      index,
      radio: false,
    );
    _service.registerPlay(station);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.turkishRadio),
        actions: <Widget>[
          IconButton(
            tooltip: strings.radioRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: _service.loading ? null : _refresh,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _service,
        builder: (context, _) {
          final list = _service.search(_query);
          return Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                child: TextField(
                  controller: _search,
                  onChanged: (value) => setState(() => _query = value),
                  decoration: InputDecoration(
                    hintText: strings.radioSearchHint,
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        strings.turkishRadioHint,
                        style: TextStyle(
                          color: AppPalette.textSubtle,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Text(
                      strings.radioStations(list.length),
                      style: TextStyle(
                        color: AppPalette.textSubtle,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (_service.error != null && list.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '${strings.radioError} · ${_service.error}',
                    style: const TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: _buildList(list, strings),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildList(List<RadioStation> list, AppStrings strings) {
    if (_service.loading && list.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (list.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: <Widget>[
          const SizedBox(height: 120),
          Icon(Icons.radio, size: 48, color: AppPalette.iconFaint),
          const SizedBox(height: 12),
          Center(child: Text(strings.radioEmpty)),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: list.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final station = list[i];
        return ListTile(
          leading: ClipOval(
            child: CachedNetworkImage(
              imageUrl: station.logoUrl,
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              placeholder: (_, __) => _logoPlaceholder,
              errorWidget: (_, __, ___) => _logoPlaceholder,
            ),
          ),
          title: Text(
            station.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            station.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.play_arrow),
          onTap: () => _play(list, i),
        );
      },
    );
  }
}
