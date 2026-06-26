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


def gen_line(i: int, jp: bool) -> str:
    """ログ1行を生成する。"""
    base = (
        f"2026-06-26 12:00:00.{i % 1000:03d} [INFO] "
        f"request_id={i} status=200 path=/api/v1/users latency=42ms"
    )
    if jp:
        frag = JP_FRAGMENTS[i % len(JP_FRAGMENTS)]
        base += f" msg={frag}"
    return base + "\n"


def write_sized(path: str, target_bytes: int, jp: bool, encoding: str) -> None:
    """指定バイト数に達するまで行を書き込む。"""
    written = 0
    i = 0
    # 8MB バッファでまとめ書き (10GB でも現実的な速度に)
    buf = []
    buf_bytes = 0
    FLUSH = 8 * 1024 * 1024
    with open(path, "w", encoding=encoding, errors="replace", newline="") as f:
        while written < target_bytes:
            line = gen_line(i, jp)
            enc_len = len(line.encode(encoding, errors="replace"))
            buf.append(line)
            buf_bytes += enc_len
            written += enc_len
            i += 1
            if buf_bytes >= FLUSH:
                f.write("".join(buf))
                buf.clear()
                buf_bytes = 0
                _progress(written, target_bytes)
        if buf:
            f.write("".join(buf))
    _progress(written, target_bytes, final=True)
    print(f"\n生成完了: {path} ({written:,} bytes, {i:,} 行, {encoding})")


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
