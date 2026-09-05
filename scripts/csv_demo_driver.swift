// 「絞り込んで、直して、元の形式のまま保存」を録るための台本ドライバ。
//
// 2026-09-05 に Threads で聞かれた:
//   「このエディターで CSV のフィルター、加工、形式を踏襲したまま保存できるんですか？
//     開いて見るだけなら選択肢多そうなんですが。」
//
// 答えを口で言わずに撮る。題材は実物の法人全件 CSV（1.06GB・Shift-JIS・CRLF・引用符つき）。
// **原本は触らない**。record_csv_demo.sh が作業用のコピーを作り、そのパスを引数で渡す。
//
//   swiftc -O scripts/csv_demo_driver.swift -o <out>/csv_demo_driver
//   <out>/csv_demo_driver place <csv>   … ウィンドウを録画枠に置く
//   <out>/csv_demo_driver act   <csv>   … 台本を演じる
//
// 前提: アクセシビリティ権限（システム設定 > プライバシー > アクセシビリティ）。

import Cocoa

// 作業用コピーのパス。原本を渡してはいけない（この台本は保存する）。
let csvPath: String = {
    let args = CommandLine.arguments
    guard args.count >= 3 else {
        fputs("使い方: csv_demo_driver <place|act> <csv のパス>\n", stderr); exit(1)
    }
    return args[2]
}()

// 録画枠 = メニューバーを除いた可視領域（1280x832 の画面で 0,29 から 1280x748）。
let shot = CGRect(x: 0, y: 29, width: 1280, height: 748)

// ---- CGEvent の下ごしらえ（demo_driver.swift と同じ） ----------------------

let src = CGEventSource(stateID: .hidSystemState)!

let codes: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
    "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
]
let kReturn: CGKeyCode = 36
let kEscape: CGKeyCode = 53
let kEnd: CGKeyCode = 119          // fn+→ 相当（行末へ）

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

/// テキストの流し込みは貼り付けで行う（IME に食われないため。demo_driver と同じ理由）。
func paste(_ s: String, replacing: Bool = true) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(s, forType: .string)
    usleep(120_000)
    if replacing { tap("a", .maskCommand); usleep(80_000) }
    tap("v", .maskCommand)
}

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

func scroll(lines: Int32, steps: Int, gap: useconds_t = 16_000) {
    for _ in 0..<steps {
        let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                        wheelCount: 1, wheel1: -lines, wheel2: 0, wheel3: 0)!
        e.post(tap: .cghidEventTap)
        usleep(gap)
    }
}

func sleep(_ sec: Double) { usleep(useconds_t(sec * 1_000_000)) }

// ---- ウィンドウ ------------------------------------------------------------

func app() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.aaedit.MrEditor").first
}

/// 前面に来たことを確かめてからでないと 1 打も打たない（打鍵が他のアプリへ飛ぶため）。
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
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &pos)!)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    print("窓を \(Int(shot.width))x\(Int(shot.height)) @ (\(Int(shot.minX)),\(Int(shot.minY))) に設置")
}

// ---- 台本 ------------------------------------------------------------------
//
// 4 幕。カットなし。
//   1. 1.06GB の Shift-JIS CSV を開く
//   2. 絞り込む（一致行だけが残る）
//   3. 絞り込みを解いて、その行を直す  ← 絞り込み中は編集できない仕様なので、隠さず見せる
//   4. 保存する
// 「触っていない byte が通り抜けている」ことは画面では見えないので、
//   撮影後に record_csv_demo.sh が cmp / xxd で示す。

func openTheCsv() {
    tap("o", .maskCommand);               sleep(1.2)   // 開くダイアログ
    tap("g", [.maskCommand, .maskShift]); sleep(0.9)   // パス指定シート
    paste(csvPath);                       sleep(0.7)
    tap(kReturn);                         sleep(1.0)   // シートを閉じてファイルを選択
    tap(kReturn)                                       // ← ここから 1.06 GB が開く
}

func act() {
    _ = activateOrDie()
    saveClipboard()
    defer { restoreClipboard() }
    let t0 = Date()
    func mark(_ name: String) {
        print("\(name) \(String(format: "%.2f", Date().timeIntervalSince(t0)))")
    }

    sleep(1.2)                                   // 空のエディタ

    // ── 1 幕: 開く ────────────────────────────────────────────────
    openTheCsv()
    sleep(2.2)                                   // 描画された瞬間を見せる
    mark("OPENED_AT")

    moveMouse(CGPoint(x: 800, y: 420)); sleep(0.3)
    scroll(lines: 90, steps: 40)                 // Shift-JIS の日本語が化けずに出ている
    sleep(1.0)

    // ── 2 幕: 絞り込む ──────────────────────────────────────────────
    // 絞り込みトグルは記憶される（record_csv_demo.sh が事前に ON にしている）ので、
    // ⌘F は絞り込み ON の状態で開く。
    tap("f", .maskCommand);            sleep(0.9)
    paste("東京都");                    sleep(0.6)
    tap(kReturn);                      sleep(2.4)   // 一致行だけになる
    mark("FILTERED_AT")
    scroll(lines: 90, steps: 30)                    // 絞り込んだ結果を読む
    sleep(1.4)

    // ── 3 幕: 絞り込みを解いて直す ────────────────────────────────────
    // **絞り込み中は編集できない**（一致行だけの非連続な並びなので入力を切っている）。
    // ここを飛ばすと嘘になるので、解除してから直すところをそのまま見せる。
    tap(kEscape);                      sleep(1.2)   // 絞り込み解除・その行に留まる
    mark("UNFILTERED_AT")
    tap(kEnd);                         sleep(0.5)   // 行末へ
    paste(",\"MrEditor で直した\"", replacing: false); sleep(1.6)
    mark("EDITED_AT")

    // ── 4 幕: 保存する ──────────────────────────────────────────────
    tap("s", .maskCommand)
    mark("SAVE_AT")
    sleep(4.0)                                   // 1.06GB の書き出しが終わるまで
    mark("END_AT")
}

/// 録画せずに「開く」だけ演じる（台本が本当に開けるかの確認用）。
func probe() {
    _ = activateOrDie()
    saveClipboard()
    defer { restoreClipboard() }
    openTheCsv()
    sleep(3.0)
    print("開けた（保存はしていない）")
}

switch CommandLine.arguments[1] {
case "place": placeWindow()
case "act":   act()
case "probe": probe()
default:
    fputs("使い方: csv_demo_driver <place|act|probe> <csv のパス>\n", stderr); exit(1)
}
