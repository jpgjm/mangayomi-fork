# Native-title display（タイトルの原題表示）

ソース（拡張機能）が返すタイトルは拡張機能の言語（ローマ字・英語など）に固定される。
この機能は、そのタイトルを AniList で照合し、見つかった `title.native`
（原語タイトル。日本の作品なら日本語）を**表示だけ**差し替える。

## 仕組み

- `lib/services/native_title/native_title_store.dart`
  - 設定フラグ・解決済みキャッシュ（正規化したソースタイトル → native）・
    作品ごとの手動指定を、アプリサポートディレクトリの `native_titles.json` に保存する。
  - Isar を使わない理由: 生成済み `*.g.dart` はコミット運用で CI は再生成しないため、
    Manga/Settings コレクションへのフィールド追加（生成コードの手編集）より
    JSON サイドカーの方が安全。
  - 照合: AniList 検索（`searchNativeTitleCandidates`、`anilist_discovery.dart`）の
    候補に対し、romaji / english / native / synonyms を正規化して比較。
    完全一致または bigram Dice ≥ 0.85 のみ採用（誤った原題は無いより悪い）。
    ソースタイトルが既に日本語（かな・漢字を含む）の場合は照合しない。
  - レート制御: 2.2 秒間隔のキュー。AniList 障害・レート制限時はバッチを中断し
    次回起動時に再開。不一致は 7 日間ネガティブキャッシュ。
- 表示は `Manga.displayName`（拡張）/ `NativeTitleStore.i.displayFor(name)` 経由。
  **機能系の用途（ダウンロードパス・移行検索・ソースへのリクエスト・メタデータ出力）は
  従来どおり `name` を使う。** DB の `Manga.name` は一切書き換えない。
- 再描画: 解決完了ごとに `NativeTitleStore.i.revision` が増え、
  `ValueListenableBuilder` を挟んだ画面（ライブラリ・詳細・履歴・ブラウズカード等）が更新される。

## UI

- 設定 → 外観 → 「タイトルを原題（native）で表示」トグル（既定 OFF）。
- 作品詳細のオーバーフローメニュー →「原題（日本語タイトル）を修正」:
  AniList を検索して候補から選択（作品ごとの手動指定、自動照合より優先）/ 解除。

## 文言について

アプリの l10n は生成ファイルをロケールごとにコミットする運用のため、
この機能の少数の文言は `native_title_dialog.dart` にローカル定義（ja/en）。
