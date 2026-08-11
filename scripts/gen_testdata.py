#!/usr/bin/env python3
"""MrEditor テスト用データ生成スクリプト。

巨大ファイル表示・文字コード判定のテスト用ファイルを生成する。

使い方:
    # 10GB の英語ログ (UTF-8)
    python3 scripts/gen_testdata.py --size 10G --out test_10gb.log

    # 1GB / 日本語混在 / UTF-8
    python3 scripts/gen_testdata.py --size 1G --jp --out test_1gb_jp_utf8.log

    # 文字コード判定テスト用の小さいファイル一式 (UTF-8 / Shift-JIS / EUC-JP)
    python3 scripts/gen_testdata.py --encoding-set --out-dir testdata/

サイズ指定: 整数 + 単位 (B/K/M/G)。例: 500M, 10G, 1500000
"""

import argparse
import os
import sys
import time

# 日本語混在の行に使う断片 (Shift-JIS / EUC-JP でも表現できる範囲)
JP_FRAGMENTS = [
    "リクエスト受信",
    "ユーザー認証成功",
    "データベース接続",
    "キャッシュ書き込み完了",
    "タイムアウト発生",
    "セッション破棄",
    "ファイル読み込み中",
    "文字コード判定: 自動",
]


def parse_size(s: str) -> int:
    """'10G' のようなサイズ文字列をバイト数に変換する。"""
    s = s.strip().upper()
    units = {"B": 1, "K": 1024, "M": 1024**2, "G": 1024**3}
    if s and s[-1] in units:
        return int(float(s[:-1]) * units[s[-1]])
    return int(s)


# ログらしさ（＝分析機能のテストに要るもの）を作る表。
#
# ⚠️ 2026-08-11 に作り直した。それまでの生成物は
#   ① 時刻がミリ秒だけ回って **0.4 秒しか進まない**（8,642 万行が 1 バケットに落ちる
#      ＝時間分布の実演も E2E もできない）
#   ② `status=200` が 100%・path も 1 種類（＝値の集計の実演にもならない）
# という状態で、分析（Pro）のテストに使えなかった。**時刻は実際に進ませ、値は散らす。**
#
# 表は素数長にしてある（i % len で拾うとき、周期が噛み合って偏らないように）。
STATUS_TABLE = (
    ["200"] * 89 + ["302"] * 5 + ["404"] * 7 + ["500"] * 2 + ["503"] * 1 + ["401"] * 3
)                                   # 107 個（200 が約 83%）
PATH_TABLE = [
    "/api/v1/users", "/api/v1/users/{id}", "/api/v1/orders", "/api/v1/orders/{id}",
    "/api/v1/search", "/api/v1/session", "/healthz", "/metrics",
    "/static/app.js", "/static/app.css", "/api/v2/graph", "/api/v1/upload",
    "/api/v1/report",
]                                   # 13 個
METHOD_TABLE = ["GET"] * 8 + ["POST"] * 3 + ["PUT"] + ["DELETE"]     # 13 個
REGION_TABLE = ["ap-northeast-1", "us-east-1", "eu-west-1"]

# 障害の窓（ファイルの 62〜64% あたり）。ここだけ流量が跳ね、500 が多数を占める。
# 「ERROR だけ絞ってから時間分布」を実演できるようにするための山。
INCIDENT_FROM = 0.62
INCIDENT_TO = 0.64
INCIDENT_STATUS = ["500"] * 7 + ["503"] * 2 + ["200"] * 3           # 12 個
# 時刻を持たない行（スタックトレースの継続行）。**捨てずに数える**ことの試験材料。
TRACE_LINES = [
    "    at com.example.OrderService.handle(OrderService.java:142)",
    "    at com.example.Repository.query(Repository.java:88)",
    "    ... 17 more",
]


class Timeline:
    """行番号から時刻を作る。**時刻は必ず前へ進む**（ログだから）。

    1 行ごとに `datetime` を作ると 8,642 万行では話にならないので、秒までの文字列は
    秒が変わったときだけ組み立て直し、ミリ秒だけを差し替える。
    """

    def __init__(self, total_lines: int, span_days: float = 14.0,
                 start_epoch: int = 1_782_000_000, tz: str = "+09:00"):
        self.total = max(1, total_lines)
        self.start = start_epoch
        self.tz = tz
        self.span_ms = int(span_days * 86_400 * 1000)
        # 平常時の間隔（ミリ秒）。障害の窓では 1/8 になる。
        self.step_ms = max(1, self.span_ms // self.total)
        self.incident_from = int(self.total * INCIDENT_FROM)
        self.incident_to = int(self.total * INCIDENT_TO)
        self._sec = -1
        self._prefix = ""

    def at(self, i: int, incident: bool) -> str:
        # 進み方を行番号だけで決める（乱数を引かない＝再現できる）。
        #
        # ⚠️ 障害の窓を抜けた後は、**詰めた分をそのまま持ち越す**。窓の中だけ間隔を詰めて
        # 後で元の式に戻すと、抜けた瞬間に時刻が飛んで**グラフに穴が空く**（最初の版が
        # そうなっていて、実機のグラフで山の直後が空白になった）。
        head = min(i, self.incident_from) * self.step_ms
        burst = max(0, min(i, self.incident_to) - self.incident_from) * self.step_ms // 8
        tail = max(0, i - self.incident_to) * self.step_ms
        base = head + burst + tail
        ms = self.start * 1000 + base + (i % 7)      # 同じ時刻に並ばないよう少しずらす
        sec, milli = divmod(ms, 1000)
        if sec != self._sec:
            self._sec = sec
            t = time.gmtime(sec + 9 * 3600)          # 表示は JST（オフセットを明示する）
            self._prefix = time.strftime("%Y-%m-%dT%H:%M:%S", t)
        return f"{self._prefix}.{milli:03d}{self.tz}"


def gen_line(i: int, jp: bool, timeline: "Timeline", total: int) -> str:
    """ログ1行を生成する。"""
    incident = INCIDENT_FROM * total <= i < INCIDENT_TO * total
    status = (INCIDENT_STATUS[i % len(INCIDENT_STATUS)] if incident
              else STATUS_TABLE[i % len(STATUS_TABLE)])
    level = "ERROR" if status in ("500", "503") else ("WARN" if status in ("404", "401") else "INFO")
    path = PATH_TABLE[i % len(PATH_TABLE)]
    method = METHOD_TABLE[i % len(METHOD_TABLE)]
    latency = (17 + (i % 400)) * (9 if incident else 1)
    base = (
        f"{timeline.at(i, incident)} [{level:<5}] "
        f"request_id={i} status={status} method={method} path={path} "
        f"latency={latency}ms region={REGION_TABLE[i % 3]}"
    )
    if jp:
        base += f" msg={JP_FRAGMENTS[i % len(JP_FRAGMENTS)]}"
    return base + "\n"


def write_sized(path: str, target_bytes: int, jp: bool, encoding: str) -> None:
    """指定バイト数に達するまで行を書き込む。

    **数えた結果を `<out>.stats.txt` に残す。** 分析機能の試験は「実データの固定値」を
    根拠にするので（仕様 §8）、生成した側の数字を後から突き合わせられるようにしておく。
    """
    written = 0
    i = 0
    # 1 行の見積もり（時刻の間隔を決めるのに要る）。行が伸びれば行数は減るが、
    # 時刻の刻みが少し粗くなるだけで、進むことに変わりはない。
    estimated_lines = max(1, target_bytes // (150 if jp else 130))
    timeline = Timeline(estimated_lines)
    stats = {"lines": 0, "no_timestamp": 0, "status": {}, "level": {}}
    first_line = last_line = ""

    buf = []
    buf_bytes = 0
    FLUSH = 8 * 1024 * 1024
    with open(path, "w", encoding=encoding, errors="replace", newline="") as f:
        while written < target_bytes:
            line = gen_line(i, jp, timeline, estimated_lines)
            lines = [line]
            # 障害の窓では、時刻を持たない継続行を混ぜる（**捨てずに数える**ことの材料）。
            if "[ERROR]" in line or "[ERROR" in line:
                if i % 5 == 0:
                    lines += [t + "\n" for t in TRACE_LINES]
                    stats["no_timestamp"] += len(TRACE_LINES)
            for one in lines:
                enc_len = len(one.encode(encoding, errors="replace"))
                buf.append(one)
                buf_bytes += enc_len
                written += enc_len
                stats["lines"] += 1
            if not first_line:
                first_line = line
            last_line = line
            status = line.split(" status=", 1)[1].split(" ", 1)[0]
            level = line.split("[", 1)[1].split("]", 1)[0].strip()
            stats["status"][status] = stats["status"].get(status, 0) + 1
            stats["level"][level] = stats["level"].get(level, 0) + 1
            i += 1
            if buf_bytes >= FLUSH:
                f.write("".join(buf))
                buf.clear()
                buf_bytes = 0
                _progress(written, target_bytes)
        if buf:
            f.write("".join(buf))
    _progress(written, target_bytes, final=True)

    report = [
        f"file: {path}",
        f"bytes: {written}",
        f"lines: {stats['lines']}",
        f"lines_without_timestamp: {stats['no_timestamp']}",
        f"first: {first_line.rstrip()}",
        f"last: {last_line.rstrip()}",
    ]
    report += [f"status {k}: {v}" for k, v in sorted(stats["status"].items())]
    report += [f"level {k}: {v}" for k, v in sorted(stats["level"].items())]
    with open(path + ".stats.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(report) + "\n")
    print("\n" + "\n".join(report))


def _progress(written: int, target: int, final: bool = False) -> None:
    pct = min(100, written * 100 // max(1, target))
    end = "\n" if final else "\r"
    print(f"  {pct:3d}%  {written/1024/1024:,.0f} MB", end=end, flush=True)


def gen_encoding_set(out_dir: str) -> None:
    """文字コード判定テスト用に同じ内容を3エンコーディングで出力する。"""
    os.makedirs(out_dir, exist_ok=True)
    targets = {
        "sample_utf8.txt": "utf-8",
        "sample_sjis.txt": "shift_jis",
        "sample_euc.txt": "euc_jp",
    }
    # 日本語をしっかり含む内容
    lines = [
        "これは文字コード判定のテストです。\n",
        "吾輩は猫である。名前はまだ無い。\n",
        "祇園精舎の鐘の声、諸行無常の響きあり。\n",
        "ABCabc123 半角と全角アルファベットＡＢＣ\n",
        "記号: ①②③ 〜 ※ 【重要】 «»\n",
    ] * 20
    text = "".join(lines)
    for name, enc in targets.items():
        path = os.path.join(out_dir, name)
        with open(path, "w", encoding=enc, errors="replace", newline="") as f:
            f.write(text)
        size = os.path.getsize(path)
        print(f"  {path}  ({enc}, {size} bytes)")
    print("文字コードセット生成完了")


def main() -> int:
    p = argparse.ArgumentParser(description="MrEditor テストデータ生成")
    p.add_argument("--size", help="生成サイズ (例: 10G, 1G, 500M)")
    p.add_argument("--out", default="test.log", help="出力ファイルパス")
    p.add_argument("--jp", action="store_true", help="日本語を混在させる")
    p.add_argument(
        "--encoding",
        default="utf-8",
        help="出力エンコーディング (utf-8 / shift_jis / euc_jp)",
    )
    p.add_argument(
        "--encoding-set",
        action="store_true",
        help="文字コード判定テスト用の3ファイルを生成",
    )
    p.add_argument("--out-dir", default="testdata", help="--encoding-set の出力先")
    args = p.parse_args()

    if args.encoding_set:
        gen_encoding_set(args.out_dir)
        return 0

    if not args.size:
        p.error("--size を指定してください (または --encoding-set)")

    target = parse_size(args.size)
    print(f"生成開始: {args.out}  target={target:,} bytes  jp={args.jp}  enc={args.encoding}")
    write_sized(args.out, target, args.jp, args.encoding)
    return 0


if __name__ == "__main__":
    sys.exit(main())
