import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/repositories/manga_repository.dart';
import 'package:mangayomi/services/anilist_discovery.dart';
import 'package:mangayomi/utils/log/logger.dart';
import 'package:path_provider/path_provider.dart';

/// Resolves source-provided titles (romaji / english / synonyms) to the
/// AniList native (original-language, usually Japanese) title, and serves
/// them for display.
///
/// Deliberately NOT stored in Isar: the generated `*.g.dart` files are
/// committed and CI does not regenerate them, so adding fields to the Manga
/// or Settings collections by hand-editing generated code is riskier than a
/// small JSON sidecar. Everything (the enabled flag, the resolved cache and
/// the per-manga manual overrides) lives in `native_titles.json` under the
/// application support directory.
class NativeTitleStore {
  NativeTitleStore._();
  static final NativeTitleStore i = NativeTitleStore._();

  /// Bumped whenever a title resolves or an override changes; title-displaying
  /// screens listen to this to repaint.
  final ValueNotifier<int> revision = ValueNotifier(0);

  bool _enabled = false;
  bool get enabled => _enabled;

  /// normalized source title -> native title
  final Map<String, String> _byTitle = {};

  /// manga id (as string) -> native title (manual override, wins over _byTitle)
  final Map<String, String> _byMangaId = {};

  /// normalized source title -> epoch ms of last failed lookup (negative cache)
  final Map<String, int> _noMatch = {};

  static const _noMatchTtl = Duration(days: 7);

  File? _file;
  bool _loaded = false;

  // ---- resolve queue ----
  final List<(String, ItemType)> _queue = [];
  final Set<String> _queued = {};
  bool _working = false;

  /// Minimum gap between AniList search calls. AniList's public API is rate
  /// limited (90/min nominal, often degraded to 30/min), so a library batch
  /// must trickle.
  static const _requestGap = Duration(milliseconds: 2200);

  Future<void> init() async {
    if (_loaded) return;
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}${Platform.pathSeparator}native_titles.json');
      if (await _file!.exists()) {
        final json =
            jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        _enabled = json['enabled'] == true;
        (json['byTitle'] as Map<String, dynamic>? ?? {}).forEach(
          (k, v) => _byTitle[k] = v as String,
        );
        (json['byMangaId'] as Map<String, dynamic>? ?? {}).forEach(
          (k, v) => _byMangaId[k] = v as String,
        );
        final now = DateTime.now().millisecondsSinceEpoch;
        (json['noMatch'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
          final ts = v as int;
          if (now - ts < _noMatchTtl.inMilliseconds) _noMatch[k] = ts;
        });
      }
      _loaded = true;
      AppLogger.log(
        'NativeTitle: loaded (enabled=$_enabled, '
        'cached=${_byTitle.length}, overrides=${_byMangaId.length})',
      );
      if (_enabled) scheduleLibraryResolve();
    } catch (e, st) {
      AppLogger.log('NativeTitle: init failed: $e\n$st',
          logLevel: LogLevel.error);
      _loaded = true; // keep running without persistence
    }
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.writeAsString(
        jsonEncode({
          'enabled': _enabled,
          'byTitle': _byTitle,
          'byMangaId': _byMangaId,
          'noMatch': _noMatch,
        }),
      );
    } catch (e) {
      AppLogger.log('NativeTitle: save failed: $e', logLevel: LogLevel.warning);
    }
  }

  void _bump() => revision.value++;

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    await _save();
    _bump();
    if (value) scheduleLibraryResolve();
  }

  /// The title to show for [manga]: manual override, then resolved cache,
  /// then the source title untouched. Never used for anything functional
  /// (downloads, migration, source requests keep `name`).
  String displayNameFor(Manga manga) {
    final name = manga.name ?? '';
    if (!_enabled) return name;
    final id = manga.id;
    if (id != null) {
      final manual = _byMangaId['$id'];
      if (manual != null && manual.isNotEmpty) return manual;
    }
    final native = _byTitle[normalizeTitle(name)];
    return (native != null && native.isNotEmpty) ? native : name;
  }

  /// Display form for a raw source title (used where only an [MManga]-style
  /// record exists, e.g. browse/search results not yet in the database).
  String displayFor(String? name) {
    final n = name ?? '';
    if (!_enabled || n.isEmpty) return n;
    final native = _byTitle[normalizeTitle(n)];
    return (native != null && native.isNotEmpty) ? native : n;
  }

  Future<void> setManualOverride(int mangaId, String? native) async {
    if (native == null || native.isEmpty) {
      _byMangaId.remove('$mangaId');
    } else {
      _byMangaId['$mangaId'] = native;
    }
    await _save();
    _bump();
  }

  String? manualOverrideFor(int mangaId) => _byMangaId['$mangaId'];

  /// Queue [manga] for AniList resolution. No-op when disabled, already
  /// cached, recently failed, or the title already looks Japanese.
  void requestResolve(Manga manga, {bool priority = false}) {
    if (manga.id != null && _byMangaId.containsKey('${manga.id}')) return;
    requestResolveRaw(manga.name, manga.itemType, priority: priority);
  }

  /// Same as [requestResolve] for places that only have a raw source title
  /// (browse / global-search results, which are MManga records not yet in
  /// the database).
  void requestResolveRaw(
    String? name,
    ItemType itemType, {
    bool priority = false,
  }) {
    if (!_enabled) return;
    if (name == null || name.trim().isEmpty) return;
    final norm = normalizeTitle(name);
    if (norm.isEmpty || _byTitle.containsKey(norm)) return;
    if (_looksJapanese(name)) return;
    if (!priority && _noMatch.containsKey(norm)) return;
    if (_queued.contains(norm)) return;
    _queued.add(norm);
    priority
        ? _queue.insert(0, (name, itemType))
        : _queue.add((name, itemType));
    _work();
  }

  /// Queue every library favorite that has no cached native title yet.
  void scheduleLibraryResolve() {
    try {
      final favorites = mangaRepository.getFavorites();
      for (final m in favorites) {
        requestResolve(m);
      }
      AppLogger.log(
        'NativeTitle: library batch queued (${_queue.length} pending)',
      );
    } catch (e) {
      AppLogger.log('NativeTitle: library batch failed: $e',
          logLevel: LogLevel.warning);
    }
  }

  Future<void> _work() async {
    if (_working) return;
    _working = true;
    try {
      while (_queue.isNotEmpty && _enabled) {
        final (name, itemType) = _queue.removeAt(0);
        final norm = normalizeTitle(name);
        _queued.remove(norm);
        if (_byTitle.containsKey(norm)) continue;
        try {
          final native = await _resolve(name, itemType);
          if (native != null) {
            _byTitle[norm] = native;
            _noMatch.remove(norm);
            AppLogger.log('NativeTitle: "$name" -> "$native"');
            await _save();
            _bump();
          } else {
            _noMatch[norm] = DateTime.now().millisecondsSinceEpoch;
            await _save();
          }
        } catch (e) {
          // AniList down / rate limited: stop the batch, retry next launch.
          AppLogger.log(
            'NativeTitle: resolve stopped ("$name"): $e',
            logLevel: LogLevel.warning,
          );
          break;
        }
        await Future.delayed(_requestGap);
      }
    } finally {
      _working = false;
    }
  }

  Future<String?> _resolve(String name, ItemType itemType) async {
    final candidates = await searchNativeTitleCandidates(itemType, name);
    final best = pickBestCandidate(name, candidates);
    final native = best?.native;
    if (native == null || native.isEmpty) return null;
    if (normalizeTitle(native) == normalizeTitle(name)) return null;
    return native;
  }

  // ---- matching ----

  static bool _looksJapanese(String s) =>
      RegExp(r'[぀-ヿ㐀-鿿]').hasMatch(s);

  /// Case/punctuation/whitespace-insensitive key.
  static String normalizeTitle(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

  /// Best candidate whose romaji/english/native/synonyms matches the source
  /// title exactly (normalized) or closely (bigram Dice >= 0.85). Null when
  /// nothing is close enough — a wrong native title is worse than none.
  static NativeTitleCandidate? pickBestCandidate(
    String sourceTitle,
    List<NativeTitleCandidate> candidates,
  ) {
    final target = normalizeTitle(sourceTitle);
    if (target.isEmpty) return null;
    NativeTitleCandidate? best;
    double bestScore = 0;
    for (final c in candidates) {
      if (c.native == null || c.native!.isEmpty) continue;
      final fields = [c.romaji, c.english, c.native, ...c.synonyms];
      double score = 0;
      for (final f in fields) {
        if (f == null || f.isEmpty) continue;
        final norm = normalizeTitle(f);
        if (norm == target) {
          score = 1.0;
          break;
        }
        final s = _dice(target, norm);
        if (s > score) score = s;
      }
      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
    }
    return bestScore >= 0.85 ? best : null;
  }

  static double _dice(String a, String b) {
    if (a == b) return 1;
    if (a.length < 2 || b.length < 2) return 0;
    final bigrams = <String, int>{};
    for (var i = 0; i < a.length - 1; i++) {
      final g = a.substring(i, i + 2);
      bigrams[g] = (bigrams[g] ?? 0) + 1;
    }
    var hits = 0;
    for (var i = 0; i < b.length - 1; i++) {
      final g = b.substring(i, i + 2);
      final n = bigrams[g] ?? 0;
      if (n > 0) {
        bigrams[g] = n - 1;
        hits++;
      }
    }
    return 2 * hits / (a.length + b.length - 2);
  }
}

/// Display-only accessor. Functional uses (download paths, migration search,
/// source requests, export) must keep using [Manga.name].
extension MangaDisplayName on Manga {
  String get displayName => NativeTitleStore.i.displayNameFor(this);
}
