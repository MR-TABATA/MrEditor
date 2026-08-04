# メトリクス

`downloads.csv` は GitHub Releases の dmg ダウンロード数のスナップショットです。
毎週月曜に [`.github/workflows/metrics.yml`](../../.github/workflows/metrics.yml) が
[`scripts/metrics_snapshot.sh`](../../scripts/metrics_snapshot.sh) を回して1行1レコードで追記します。
告知の直後など任意のタイミングで撮りたいときは、Actions から手動実行できます。

なぜ撮るのか: **GitHub API は「今の累計」しか返さず、履歴を持たない。**
「あの告知で何件増えたか」は、前後で撮ったスナップショットの差分でしか出せません。

## この数字が何ではないか

`download_count` は **ユニークな人数ではありません。**

- クローラやミラーのアクセスも 1 件として乗ります。
- 更新チェッカ経由で新版を取り直した既存利用者も、新しい版の 1 件になります。
- 同じ人が入れ直せばその回数だけ増えます。

**「◯◯人が使っています」とは書けません。**「dmg のダウンロードが累計 N 件」までが言える範囲です。

## 手元で見る

```sh
sh scripts/metrics_snapshot.sh          # 撮って合計と前回差分を表示
```

```sh
# 版ごとの最新値
awk -F, 'NR>1{gsub(/"/,"",$1); if($1>d) d=$1} END{print d}' docs/metrics/downloads.csv
```
