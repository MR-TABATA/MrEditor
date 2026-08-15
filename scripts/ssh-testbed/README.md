# SSH テストベッド / SSH testbed

SSH 越しにファイルを開く機能（ROADMAP の B5 / C7）を検証するための Linux ホスト群です。
docker で 5 台建てます。Mac の sshd では踏めない入口を踏むために置いています。

A set of throwaway Linux hosts for verifying MrEditor's SSH support. Five containers,
covering the entry points that a Mac's own `sshd` cannot exercise.

## なぜ Mac だけでは足りないか

- **道具が違う**。macOS は BSD 系の `stat` / `tail` / `sed`、実際のログサーバは GNU 系。
  shell out して出力を解釈する以上、ここは実物で踏まないと出荷後に壊れます。
- **踏み台が要る**。`ssh -J localhost localhost` は自己ジャンプで、経路が本物ではない。
  ここでは `inner` がポートを一切公開せず、`jump` 経由でしか到達できません。
- **喋るサーバが要る**。ログイン時の MOTD が stdout に混ざるのは Linux でしか起きません。

## 建てる

```sh
colima start          # docker が動いていなければ
sh run.sh up
sh run.sh config >> ~/.ssh/config
sh run.sh check
```

`run.sh keys` が作る鍵は `keys/` に入り、**git 管理外**です（公開リポジトリに秘密鍵は置きません）。
ホスト鍵も固定してあるので、建て直しても手元の `known_hosts` は汚れません。

## 5 台の役割

| ホスト | 何を踏むか |
|---|---|
| `mred-deb` | Debian / glibc / GNU coreutils。既定の検証先 |
| `mred-alma` | AlmaLinux。RHEL 系との差（coreutils の版・sshd の既定） |
| `mred-pw` | **パスワード認証のみ**。`SSH_ASKPASS` の経路（`mred` / `mred`） |
| `mred-jump` | 踏み台。edge と inner の両方に足を持つ |
| `mred-inner` | **ポート非公開**。`mred-jump` 経由でしか届かない = ProxyJump の実地検証 |

各ホストの `/srv/logs/app.log` に 200 行のサンプル（25 行ごとに `ERROR`）が置いてあります。

## 10GB を差し込む

```sh
sh run.sh up-big      # testdata/test_10gb.log を deb の /srv/logs/big.log へ read-only で
```

> ⚠️ **この経路で測った速度を公表しないこと。** colima の仮想ファイルシステムを挟むので、
> 実際のリモートの数字ではありません。オフセット計算・`dd skip=`・`tail -c +N` の
> **正しさ**の検証にだけ使ってください。

## 遅延を入れる

localhost は 0ms・GB/s です。**遅延の無い環境で作ると体感設計（進捗表示・転送量の見積り・
どこで諦めるか）が全部間違ったまま完成します。** 一度は Network Link Conditioner か
`dnctl` / `pfctl` で 50〜200ms を挿して触ってください。

## 畳む

```sh
sh run.sh down        # 鍵は残るので次回は up だけでよい
```
