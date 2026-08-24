# metrics ブランチ

`downloads.csv` — GitHub Releases の dmg ダウンロード数のスナップショット。
[`.github/workflows/metrics.yml`](https://github.com/MR-TABATA/MrEditor/blob/main/.github/workflows/metrics.yml)
が毎日と各リリース公開時に追記する。**コードは入っていない。**

なぜ main ではないのか:
main のルールセットは `required_status_checks` を要求するが、ボットの直 push には
PR が無いので `test` が走らず、構造上どうやっても通らない（2026-08-24 の撮影が
これで落ちた）。bypass を開けて main を緩めるより、データを別のブランチへ出すほうが
筋がよい。毎日 38 行ずつ増えるデータでコードの履歴を埋めずに済む副次効果もある。

読み方・撮り方は main の
[`docs/metrics/README.md`](https://github.com/MR-TABATA/MrEditor/blob/main/docs/metrics/README.md)。
