import 'package:flutter/material.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/services/anilist_discovery.dart';
import 'package:mangayomi/services/native_title/native_title_store.dart';

// The app's l10n keys are generated and committed per locale, so this
// feature keeps its few strings local (ja/en) instead of touching ~30
// generated localization files.
bool _ja(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'ja';

String nativeTitleMenuLabel(BuildContext context) =>
    _ja(context) ? '原題（日本語タイトル）を修正' : 'Fix native title';

String nativeTitleSettingTitle(BuildContext context) =>
    _ja(context) ? 'タイトルを原題（native）で表示' : 'Show titles in native language';

String nativeTitleSettingSubtitle(BuildContext context) => _ja(context)
    ? 'ソースのタイトルを AniList で照合し、見つかった原題（日本語など）で表示します'
    : 'Match source titles on AniList and display the native title when found';

/// Search AniList and let the user pick (or clear) the native title shown for
/// [manga]. The pick is stored as a per-manga manual override.
Future<void> showNativeTitleDialog(BuildContext context, Manga manga) async {
  await showDialog(
    context: context,
    builder: (context) => _NativeTitleDialog(manga: manga),
  );
}

class _NativeTitleDialog extends StatefulWidget {
  final Manga manga;
  const _NativeTitleDialog({required this.manga});

  @override
  State<_NativeTitleDialog> createState() => _NativeTitleDialogState();
}

class _NativeTitleDialogState extends State<_NativeTitleDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.manga.name ?? '',
  );
  List<NativeTitleCandidate> _results = const [];
  bool _searching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await searchNativeTitleCandidates(
        widget.manga.itemType,
        query,
      );
      if (!mounted) return;
      setState(() {
        _results = results.where((c) => (c.native ?? '').isNotEmpty).toList();
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = '$e';
      });
    }
  }

  Future<void> _pick(NativeTitleCandidate c) async {
    final id = widget.manga.id;
    if (id != null) {
      await NativeTitleStore.i.setManualOverride(id, c.native);
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _clear() async {
    final id = widget.manga.id;
    if (id != null) {
      await NativeTitleStore.i.setManualOverride(id, null);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ja = _ja(context);
    final hasOverride =
        widget.manga.id != null &&
        NativeTitleStore.i.manualOverrideFor(widget.manga.id!) != null;
    return AlertDialog(
      title: Text(nativeTitleMenuLabel(context)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: ja ? 'AniList を検索' : 'Search AniList',
                suffixIcon: IconButton(
                  tooltip: MaterialLocalizations.of(
                    context,
                  ).searchFieldLabel,
                  icon: const Icon(Icons.search),
                  onPressed: _search,
                ),
              ),
              onSubmitted: (_) => _search(),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    )
                  : _results.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        ja
                            ? '原題つきの候補が見つかりません'
                            : 'No candidates with a native title',
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final c = _results[index];
                        final meta = [
                          if (c.format != null) c.format!,
                          if (c.seasonYear != null) '${c.seasonYear}',
                        ].join(' · ');
                        return ListTile(
                          dense: true,
                          title: Text(c.native!),
                          subtitle: Text(
                            [
                              if (c.romaji != null) c.romaji!,
                              if (meta.isNotEmpty) meta,
                            ].join('\n'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _pick(c),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (hasOverride)
          TextButton(
            onPressed: _clear,
            child: Text(ja ? '手動設定を解除' : 'Clear override'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
      ],
    );
  }
}
