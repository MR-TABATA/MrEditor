# 要望の受け方と、返事の約束

MrEditor への要望は、**7日以内に必ず返事をする**。返事は、採用・検討中・やらない のどれか。
**「やらない」場合も、理由を書いて返す。** 採用した要望は、リリースの更新履歴に「この要望を採用した」と書く。

## 送る側

- アプリのヘルプメニュー →「要望を送る…」。GitHub の Issue フォームが、ブラウザで開く
  （バージョンと OS は最初から入る）。GitHub のアカウントが要る。
- 送った要望と状況は、公開の一覧で誰でも見られる:
  <https://mr-tabata.github.io/MrEditor/requests.ja.html>（英語: `requests.html`）。
  ヘルプメニューの「要望の状況を見る…」からも開く。

## 状況（Issue のラベル。常に1つ）

| ラベル | 意味 |
|---|---|
| `status:received` | 受付。**受け付けた日から7日以内に、下のどれかへ動かす** |
| `status:considering` | 検討中 |
| `status:adopted` | 採用（まだ作っていない） |
| `status:in-progress` | 実装中 |
| `status:done` | 完了（閉じるとボットが付ける） |
| `status:declined` | やらない（理由つき） |
| `overdue` | 受付のまま7日を過ぎた（ボットが付ける。状況を動かすと外れる） |

すべての要望には `request` ラベルが付く（Issue フォームが付ける）。

## 初回だけ

この仕組みを `main` に入れたら、Actions の **Requests** を1回、手で実行する（`gh workflow run requests.yml`）。
状況のラベルが作られる。忘れても、Issue フォームの題名「[要望]」から、ボットが `request` ラベルを付ける。
先に **サイトを公開**（`pages.yml` を動かす）してから、要望の受け口を入れたアプリを出す
（出すまで、ヘルプメニューの一覧のリンクは、まだ開けない）。

## 持ち主（あなた）がやること

1. 要望が来たら、ボットが期限（受付日 + 7日）を書いたコメントを付ける。通知が来る。
2. 7日以内に、**状況のラベルを動かす**。採用・検討中なら、ひとこと返す。
3. **やらない場合: 理由をコメントで書いてから、「Close as not planned」で閉じる。**
   理由（12文字以上の、持ち主側のコメント）が無いまま閉じると、ボットが**開き直して**理由を求める。
   理由は、公開の一覧にも載る。
4. 作ったら、Issue を閉じる（`status:done` になる）。リリースノートには、次で節を作って貼る:

   ```sh
   python3 scripts/adopted_requests.py --since v1.20.0   # 直前の版のタグ
   ```

5. 受付のまま7日を過ぎると、毎日 9:00 JST の確認が `overdue` を付け、`@持ち主` に知らせる。

## 仕組み（ファイル）

| 役割 | ファイル |
|---|---|
| 受け口（Issue フォーム） | `.github/ISSUE_TEMPLATE/request.yml`, `config.yml` |
| 返事の約束を守らせる | `.github/workflows/requests.yml` → `scripts/requests_bot.mjs`（テスト: `requests_bot.test.mjs`） |
| 公開の一覧 | `scripts/build_requests.py` → `site/requests.html` / `requests.ja.html`（`pages.yml` が作る。コミットしない） |
| 更新履歴の節 | `scripts/adopted_requests.py` |
| アプリのヘルプメニュー | `AppInfo.requestFormURL` / `requestListURL`（Info.plist の宣言を読む） |

## Pro 版（MrkEditor）には出さない

この core は、無料版と Pro 版の両方が使う。受け口の URL は core に焼き付けず、**`scripts/make_app.sh` が、
無料版のバンドル ID（`com.aaedit.MrEditor`）にだけ**、Info.plist へ書く（更新確認の feed と同じ作り）。
宣言が無い Pro 版には、メニュー項目が出ない。Pro 側にも出したいときは、Pro の側で `REQUEST_FORM` /
`REQUEST_LIST` を渡す（別の受け口を使うこと）。

## 確認

```sh
node --test scripts/requests_bot.test.mjs
python3 -m unittest scripts/test_build_requests.py scripts/test_adopted_requests.py
swift test --filter RequestURLTests
```
