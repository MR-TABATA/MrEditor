// LP 用デモ録画の台本ドライバ。
// 画面録画（screencapture -v）と並走し、CGEvent で .app を人手と同じように叩く。
// 手の震えも誤クリックも入らないので、撮り直しは再実行するだけで同じ画になる。
//
//   swiftc -O scripts/demo_driver.swift -o <out>/demo_driver
//   <out>/demo_driver place   … ウィンドウを録画枠にぴったり置く
//   <out>/demo_driver act     … 台本を演じる（約30秒）
//
// 前提: アクセシビリティ権限（システム設定 > プライバシー > アクセシビリティ）。

import Cocoa

let logPath = "/Users/hitoshi/Git/MrEditor/testdata/test_10gb.log"

// 録画枠 = メニューバーを除いた可視領域（1280x832 の画面で 0,29 から 1280x748）。
let shot = CGRect(x: 0, y: 29, width: 1280, height: 748)

// ---- CGEvent の下ごしらえ ------------------------------------------------

let src = CGEventSource(stateID: .hidSystemState)!

let codes: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
    "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
]
let kReturn: CGKeyCode = 36
let kEscape: CGKeyCode = 53

func tap(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
        usleep(12_000)
    }
}

func tap(_ c: Character, _ flags: CGEventFlags = []) {
    guard let code = codes[c] else { return }
    tap(code, flags)
}

/// テキストフィールドへの流し込みは、すべてこれで行う。
///
/// キーを1つずつ叩く方式は2つの理由で使えない:
///   - virtualKey:0 の合成 Unicode イベントは NSOpenPanel が無視する
///   - 実キーコードで数字を打つと日本語 IME に食われ、全角「８６，４２０，３３７」になる。
///     すると Return は変換確定に消費されてボタンに届かず、Int() のパースも落ちて跳ばない。
/// 貼り付けは IME を素通りするので、どちらの罠も踏まない。
func paste(_ s: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(s, forType: .string)
    usleep(120_000)          // 貼り付け前にペーストボードが確定するのを待つ
    tap("a", .maskCommand)   // 既存の値（前回の履歴）を選択して置き換える
    usleep(80_000)
    tap("v", .maskCommand)
}

/// 撮影でユーザのクリップボードを壊さないための退避と復元。
var savedClipboard: String?
func saveClipboard()    { savedClipboard = NSPasteboard.general.string(forType: .string) }
func restoreClipboard() {
    guard let s = savedClipboard else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(s, forType: .string)
}

func moveMouse(_ p: CGPoint) {
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

/// 慣性なしの素直なホイール。lines 単位だと粗いので pixel 単位で流す。
func scroll(lines: Int32, steps: Int, gap: useconds_t = 16_000) {
    for _ in 0..<steps {
        let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                        wheelCount: 1, wheel1: -lines, wheel2: 0, wheel3: 0)!
        e.post(tap: .cghidEventTap)
        usleep(gap)
    }
}

func sleep(_ sec: Double) { usleep(useconds_t(sec * 1_000_000)) }

// ---- ウィンドウを録画枠に合わせる ----------------------------------------

func app() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.aaedit.MrEditor").first
}

/// MrEditor を前面に出し、本当に前面に来たことを確かめる。
///
/// CGEvent は「最前面のアプリ」に飛ぶ。アプリが起動していない・前面に来ていない状態で
/// 打鍵すると、エディタや端末にパスや行番号を打ち込んでしまう（実際にやらかした）。
/// 確認できなければ、1 打も打たずに落ちる。
func activateOrDie() -> NSRunningApplication {
    guard let a = app() else {
        fputs("中止: MrEditor が起動していない（キー入力が他のアプリへ飛ぶため打たない）\n", stderr)
        exit(1)
    }
    a.activate(options: [])
    sleep(1.0)
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    guard front == "com.aaedit.MrEditor" else {
        fputs("中止: MrEditor が前面に来ていない（前面 = \(front ?? "不明")）\n", stderr)
        exit(1)
    }
    return a
}

func placeWindow() {
    guard let a = app() else { fputs("MrEditor が起動していない\n", stderr); exit(1) }
    a.activate(options: [])
    sleep(0.6)

    let ax = AXUIElementCreateApplication(a.processIdentifier)
    var windows: AnyObject?
    AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &windows)
    guard let list = windows as? [AXUIElement], let w = list.first else {
        fputs("ウィンドウが取れない（アクセシビリティ権限は？）\n", stderr); exit(1)
    }
    var pos = shot.origin
    var size = shot.size
    let posV = AXValueCreate(.cgPoint, &pos)!
    let sizeV = AXValueCreate(.cgSize, &size)!
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, posV)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sizeV)
    print("窓を \(Int(shot.width))x\(Int(shot.height)) @ (\(Int(shot.minX)),\(Int(shot.minY))) に設置")
}

// ---- 台本 ----------------------------------------------------------------
//
// カットなし・等倍の一発撮り。索引の約9秒を隠さず、その間に読む・検索するのを見せる。
// 「止まらない」ことの証明なので、ここを早送りしたら意味が消える。

/// 10.00 GB を開くところまで。台本と probe で共有する。
func openTheLog() {
    tap("o", .maskCommand);               sleep(1.2)   // 開くダイアログ
    tap("g", [.maskCommand, .maskShift]); sleep(0.9)   // パス指定シート
    paste(logPath);                       sleep(0.7)
    tap(kReturn);                         sleep(1.0)   // シートを閉じてファイルを選択
    tap(kReturn)                                       // ← ここから 10.00 GB が開く
}

func act() {
    _ = activateOrDie()
    saveClipboard()
    defer { restoreClipboard() }
    let t0 = Date()
    func elapsed() -> Double { Date().timeIntervalSince(t0) }

    sleep(1.4)                                   // 空のエディタ

    openTheLog()
    sleep(2.4)                                   // 描画された瞬間を見せる（実測 65〜83ms）

    // 索引が背景で走っている最中に、普通に読む
    moveMouse(CGPoint(x: 800, y: 420)); sleep(0.3)
    scroll(lines: 90, steps: 55)                 // 約1秒、指なりのスクロール
    sleep(0.6)
    scroll(lines: 140, steps: 70)
    sleep(1.0)

    // 索引中でも検索できる
    tap("f", .maskCommand);            sleep(0.8)
    paste("タイムアウト発生");           sleep(0.7)
    tap(kReturn);                      sleep(1.2)
    tap("g", .maskCommand);            sleep(0.9)
    tap("g", .maskCommand);            sleep(0.9)
    tap("g", .maskCommand);            sleep(1.0)
    tap(kEscape);                      sleep(0.8)

    scroll(lines: 120, steps: 60)
    sleep(1.2)

    // 索引の完了を待つ。ステータスバーの行数が「約 89,292,800 行」から正確な 86,420,337 に収束する。
    // 10GB で実測 約10秒（開いてから）。ここまでで既に約15秒経っているので、余裕分だけ待つ。
    sleep(3.0)

    // 最後の行へ。索引が終わっているので 0.1ms で着く。
    tap("l", .maskCommand);            sleep(1.0)
    paste("86420337");                 sleep(0.9)
    tap(kReturn)
    // 尺は勘で決めない。着地の瞬間を秒で吐き、切り出しはこの値に従わせる。
    print("JUMP_AT \(String(format: "%.2f", elapsed()))")
    sleep(3.0)                                   // 着地を見せて終わり
    print("END_AT \(String(format: "%.2f", elapsed()))")
}

/// 録画せずに「開く」だけ演じる。台本が本当にファイルを開けるかの確認用。
func probe() {
    _ = activateOrDie()
    saveClipboard()
    defer { restoreClipboard() }
    openTheLog()
    sleep(3.0)
    print("probe 完了（この時点で 10GB が開いているはず）")
}

// ---- entry ---------------------------------------------------------------

switch CommandLine.arguments.dropFirst().first {
case "place": placeWindow()
case "act":   act()
case "probe": probe()
default:
    fputs("usage: demo_driver place|act|probe\n", stderr)
    exit(2)
}
