/*
 *     Copyright (C) 2026 Valeri Gokadze
 *
 *     Musify is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     Musify is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 *
 *     For more information about Musify, including how to contribute,
 *     please visit: https://github.com/gokadzev/Musify
 */

import 'dart:io' show Platform;

import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:melody/constants/app_constants.dart';
import 'package:melody/services/settings_manager.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

BorderRadius getItemBorderRadius(
  int index,
  int totalLength, {
  bool hasItemsBefore = false,
  bool hasItemsAfter = false,
}) {
  // Determine if this item is the absolute top or absolute bottom of the visual block
  final isAbsoluteFirst = index == 0 && !hasItemsBefore;
  final isAbsoluteLast = index == totalLength - 1 && !hasItemsAfter;

  if (isAbsoluteFirst && isAbsoluteLast) {
    return commonCustomBarRadius; // Single item in the entire block
  } else if (isAbsoluteFirst) {
    return commonCustomBarRadiusFirst; // Top of the block
  } else if (isAbsoluteLast) {
    return commonCustomBarRadiusLast; // Bottom of the block
  }
  return BorderRadius.zero; // Default for middle items
}

ValueKey<int> listItemKey(String scope, int index, [Object? item]) {
  return ValueKey<int>(Object.hash(scope, index, item));
}

/// Reads a stored/decoded `List` of maps back into typed maps, dropping any
/// entry that is not a map. Returns an empty list for anything else.
List<Map<String, dynamic>> asMapList(dynamic value) {
  if (value is! List) return const [];
  return value.whereType<Map>().map(Map<String, dynamic>.from).toList();
}

/// Validates if a URL is a YouTube playlist URL
bool isYoutubePlaylistUrl(String url) {
  return _youtubePlaylistRegExp.hasMatch(url);
}

/// Extracts the playlist ID from a YouTube playlist URL
String? extractYoutubePlaylistId(String url) {
  if (!isYoutubePlaylistUrl(url)) {
    return null;
  }

  final match = _youtubePlaylistIdRegExp.firstMatch(url);
  return match?.group(1);
}

double getResponsiveTitleFontSize(Size size) {
  final isDesktop = size.width > 800;
  final isLandscape = size.width > size.height;
  if (isDesktop || isLandscape) return 20;
  if (size.width < 360) return 20;
  if (size.width < 400) return 22;
  return size.height * 0.028;
}

double getResponsiveArtistFontSize(Size size) {
  final isDesktop = size.width > 800;
  final isLandscape = size.width > size.height;
  if (isDesktop || isLandscape) return 14;
  if (size.width < 360) return 14;
  if (size.width < 400) return 15;
  return size.height * 0.018;
}

final RegExp _youtubePlaylistRegExp = RegExp(
  r'^(https?:\/\/)?(www\.|m\.|music\.)?(youtube\.com|youtu\.be)\/.*(list=([a-zA-Z0-9_-]+)).*$',
);

final RegExp _youtubePlaylistIdRegExp = RegExp('[&?]list=([a-zA-Z0-9_-]+)');

bool isSponsorshipAnnouncementUrl(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase();
  return host != null && (host == 'ko-fi.com' || host.endsWith('.ko-fi.com'));
}

/// Formats a [monthKey] (e.g. "2026-06") into a locale-aware month label
/// such as "June 2026". Falls back to [monthKey] if parsing fails.
String formatMonthPeriodLabel(Locale locale, String monthKey) {
  final parts = monthKey.split('-');
  if (parts.length != 2) return monthKey;

  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  if (year == null || month == null) return monthKey;

  final label = DateFormat.yMMMM(locale.toString()).format(
    DateTime(year, month),
  );
  return label.isEmpty
      ? monthKey
      : '${label[0].toUpperCase()}${label.substring(1)}';
}

enum _PlaybackCodec { opus, vorbis, aac, unsupported }

_PlaybackCodec _codecOf(AudioOnlyStreamInfo stream) {
  final codec = stream.codec.toString().toLowerCase();
  if (_isDolbyCodec(codec)) return _PlaybackCodec.unsupported;
  if (codec.contains('opus')) return _PlaybackCodec.opus;
  if (codec.contains('vorbis')) return _PlaybackCodec.vorbis;
  if (codec.contains('mp4a') || codec.contains('aac')) {
    return _PlaybackCodec.aac;
  }
  return _PlaybackCodec.unsupported;
}

/// Whether the app's audio backend on this platform can decode [codec].
///
/// iOS's AVPlayer only plays AAC-in-M4A/MP4, so Opus (WebM) streams must never
/// be picked on iPhones — otherwise the track silently fails to start. Android
/// (ExoPlayer) and desktop (media_kit) decode Opus/Vorbis natively, so they're
/// free to use the best-sounding codec.
bool _isStreamPlayableOnThisPlatform(_PlaybackCodec codec) {
  if (codec == _PlaybackCodec.unsupported) return false;
  if (Platform.isIOS) return codec == _PlaybackCodec.aac;
  return true;
}

/// Relative perceptual quality of a codec at a given bitrate. Opus is the most
/// transparent codec on YouTube (~transparent from 128 kbps), followed by
/// Vorbis and AAC. The multiplier is used as a tie-breaker so that "high"
/// prefers, e.g., 160 kbps Opus over 129 kbps AAC, while a genuinely
/// higher-bitrate AAC stream (256 kbps premium tracks) still wins when it is
/// truly better.
const Map<_PlaybackCodec, double> _codecQualityFactor = {
  _PlaybackCodec.opus: 1.35,
  _PlaybackCodec.vorbis: 1.10,
  _PlaybackCodec.aac: 1.0,
};

double _audioQualityScore(AudioOnlyStreamInfo stream) {
  final codec = _codecOf(stream);
  return stream.bitrate.bitsPerSecond * (_codecQualityFactor[codec] ?? 0);
}

/// Picks the stream that best matches the user's quality setting while still
/// being guaranteed to play on this platform.
///
/// * iOS keeps only AAC-in-M4A streams (everything AVPlayer can decode) and
///   "high" plays the best of those.
/// * Android/desktop prefer Opus at its ~160 kbps rate, falling back to the
///   highest scoring stream when only other codecs are available.
///
/// No stream is ever transcoded or resampled on the way to the speaker, so the
/// chosen audio quality reaches the headphones losslessly.
AudioOnlyStreamInfo selectAudioOnlyStreamForQuality(
  List<AudioOnlyStreamInfo> availableSources,
) {
  final playable = availableSources
      .where((stream) => _isStreamPlayableOnThisPlatform(_codecOf(stream)))
      .toList();
  if (playable.isEmpty) {
    return availableSources.withHighestBitrate();
  }

  playable.sort(
    (a, b) => _audioQualityScore(a).compareTo(_audioQualityScore(b)),
  );

  final qualitySetting = audioQualitySetting.value;
  if (qualitySetting == 'low') {
    return playable.first;
  } else if (qualitySetting == 'medium') {
    return playable[playable.length ~/ 2];
  }

  return playable.last;
}

bool _isDolbyCodec(String codec) {
  return codec.contains('ec-3') ||
      codec.contains('ac-3') ||
      codec.contains('eac3') ||
      codec.contains('dolby');
}
