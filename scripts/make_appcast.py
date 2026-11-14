#!/usr/bin/env python3
"""Sparkle の appcast.xml に、1 つの版（item）を足す。

    python3 scripts/make_appcast.py \
        --appcast ~/Git/MrkTools/public/downloads/mreditor/appcast.xml \
        --version 1.29.0 --dmg .build/MrEditor-1.29.0.dmg \
        --signature <sign_update が出した edSignature> --notes notes-1.29.0.md

- 同じ版が既にあれば置き換える（同じ版のやり直しで、item が二重にならない）。
- 新しい版を先頭に置く。
- 署名（edSignature）は、`sign_update` が、キーチェーンの秘密鍵で作る。このスクリプトは鍵に触れない。
- appcast の置き場所（MrkTools）は、このスクリプトでは、コミットも push もしない。

リリースノートは、本文を `<pre>` に入れて、Sparkle の更新画面にそのまま出す。
"""
from __future__ import annotations

import argparse
import base64
import binascii
import html
import os
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from xml.etree import ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

REPO = "MR-TABATA/MrEditor"
APP_NAME = "MrEditor"
MIN_SYSTEM = "13.0"


def q(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


def release_url(version: str, dmg_name: str) -> str:
    return f"https://github.com/{REPO}/releases/download/v{version}/{dmg_name}"


def notes_html(text: str) -> str:
    body = html.escape(text.strip())
    return f'<pre style="white-space: pre-wrap; font-family: -apple-system, sans-serif; font-size: 13px;">{body}</pre>'


def build_item(*, version: str, url: str, length: int, signature: str,
               notes: str, pub_date: datetime) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"{APP_NAME} {version}"
    ET.SubElement(item, "pubDate").text = format_datetime(pub_date)
    ET.SubElement(item, q("version")).text = version
    ET.SubElement(item, q("shortVersionString")).text = version
    ET.SubElement(item, q("minimumSystemVersion")).text = MIN_SYSTEM
    ET.SubElement(item, "description").text = notes_html(notes)
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", url)
    enclosure.set("length", str(length))
    enclosure.set("type", "application/octet-stream")
    enclosure.set(q("edSignature"), signature)
    return item


def empty_channel() -> ET.ElementTree:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = f"{APP_NAME} updates"
    ET.SubElement(channel, "link").text = f"https://github.com/{REPO}"
    ET.SubElement(channel, "description").text = f"Most recent changes of {APP_NAME}."
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)


def add_item(tree: ET.ElementTree, item: ET.Element) -> None:
    channel = tree.getroot().find("channel")
    if channel is None:
        raise ValueError("appcast に <channel> がない")
    version = item.findtext(q("version"))
    # 同じ版は置き換える
    for old in list(channel.findall("item")):
        if old.findtext(q("version")) == version:
            channel.remove(old)
    # 新しい版を先頭（最初の <item> の位置）に置く
    children = list(channel)
    first_item = next((i for i, c in enumerate(children) if c.tag == "item"), len(children))
    channel.insert(first_item, item)


def write_tree(tree: ET.ElementTree, path: str) -> None:
    """一時ファイルに書いてから置き換える（途中で失敗しても、既存の appcast を壊さない）。"""
    ET.indent(tree, space="  ")
    tmp = f"{path}.tmp-{os.getpid()}"
    try:
        tree.write(tmp, encoding="utf-8", xml_declaration=True)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def valid_signature(sig: str) -> bool:
    """Sparkle の EdDSA 署名は、base64 で 64 バイト（88 文字）。"""
    try:
        return len(base64.b64decode(sig, validate=True)) == 64
    except (binascii.Error, ValueError):
        return False


def versions_in(path: str) -> list[str]:
    root = ET.parse(path).getroot()
    return [i.findtext(q("version")) or "" for i in root.iter("item")]


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--appcast", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--dmg", required=True)
    ap.add_argument("--signature", required=True)
    ap.add_argument("--notes", required=True)
    args = ap.parse_args(argv)

    if not os.path.isfile(args.dmg):
        print(f"dmg が無い: {args.dmg}", file=sys.stderr)
        return 1
    if not os.path.isfile(args.notes):
        print(f"ノートが無い: {args.notes}", file=sys.stderr)
        return 1
    sig = args.signature.strip()
    if not valid_signature(sig):
        print("署名が ed25519 の形式（base64 で 64 バイト）ではない（sign_update の出力か確認）", file=sys.stderr)
        return 1

    length = os.path.getsize(args.dmg)
    url = release_url(args.version, os.path.basename(args.dmg))
    with open(args.notes, encoding="utf-8") as f:
        notes = f.read()
    item = build_item(version=args.version, url=url, length=length, signature=sig,
                      notes=notes, pub_date=datetime.now(timezone.utc))

    try:
        if os.path.exists(args.appcast):
            tree = ET.parse(args.appcast)
        else:
            os.makedirs(os.path.dirname(os.path.abspath(args.appcast)), exist_ok=True)
            tree = empty_channel()
        add_item(tree, item)
    except (ET.ParseError, ValueError) as e:
        print(f"既存の appcast を読めない（触らずに止める）: {args.appcast}: {e}", file=sys.stderr)
        return 1
    write_tree(tree, args.appcast)
    print(f"appcast に {args.version} を書いた: {args.appcast}（{len(versions_in(args.appcast))} 件）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
