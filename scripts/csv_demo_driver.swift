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

// 本文いちばん上の行の座標（画面座標・実測）。行送りは約 15pt。
// 窓を録画枠に置いたあとの値なので、枠を変えたらここも測り直すこと。
let firstRow = CGPoint(x: 620, y: 87)

// ツールバーいちばん左のボタン＝サイドバーの開閉（画面座標・実測）。
// 録画前に畳む。サイドバーには**本人の未保存の下書き**が並ぶので、公開する画に
// 入れない（消すのは危ないので、隠すだけにする）。
let sidebarToggle = CGPoint(x: 1001, y: 55)

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
let kRight: CGKeyCode = 124        // →（⌘→ で行末へ）

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

/// クリックしてキャレットを置く。
///
/// **これが要る。** ビューアのキャレットは既定で 0 にあり、`End`（keyCode 119）は
/// キャレットではなく表示をいちばん下へ送るだけ（`PieceTableViewer.handleKeyDown`）。
/// クリックせずに打つと、絞り込んで見つけた行ではなく**1 行目の先頭**に入る
/// （2026-09-05 の 1 本目がそれで撮り直しになった）。
func click(_ p: CGPoint) {
    moveMouse(p); usleep(120_000)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(60_000)
    }
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

/// ウィンドウを録画枠に置く。**置けたことを読み返して確かめる。**
///
/// 一度置くだけでは足りない。ファイルを開いた直後はアプリ側が自分の記憶した枠を
/// あとから当ててくるので、置いた指定が静かに上書きされる（2026-09-05 の 3 本目が
/// これで、窓が 1040x744 のまま録れて以降の座標が全部ずれた）。
/// 座標で叩く台本なので、ここがずれると**後ろが全部無言で外れる**。
func placeWindow() {
    guard let a = app() else { fputs("MrEditor が起動していない\n", stderr); exit(1) }
    a.activate(options: [])
    sleep(0.6)
    let ax = AXUIElementCreateApplication(a.processIdentifier)

    /// 本体の窓。**`windows` の先頭を採ってはいけない** ── ツールチップのような
    /// 小さい窓が先に来ることがある（実際に 141x18 の窓を掴んで、置いたつもりで
    /// 置けていなかった）。main window を優先し、無ければいちばん大きいものを採る。
    func frontWindow() -> AXUIElement? {
        var main: AnyObject?
        if AXUIElementCopyAttributeValue(ax, kAXMainWindowAttribute as CFString, &main) == .success,
           let m = main, CFGetTypeID(m) == AXUIElementGetTypeID() {
            return (m as! AXUIElement)
        }
        var windows: AnyObject?
        AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &windows)
        guard let list = windows as? [AXUIElement] else { return nil }
        return list.max { a, b in area(a) < area(b) }
    }

    func area(_ w: AXUIElement) -> CGFloat {
        var sizeV: AnyObject?
        AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeV)
        var sz = CGSize.zero
        guard let sizeV, AXValueGetValue(sizeV as! AXValue, .cgSize, &sz) else { return 0 }
        return sz.width * sz.height
    }
    func read(_ w: AXUIElement) -> CGRect? {
        var posV: AnyObject?, sizeV: AnyObject?
        AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posV)
        AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeV)
        var p = CGPoint.zero, sz = CGSize.zero
        guard let posV, let sizeV,
              AXValueGetValue(posV as! AXValue, .cgPoint, &p),
              AXValueGetValue(sizeV as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: p, size: sz)
    }

    for attempt in 1...6 {
        guard let w = frontWindow() else {
            fputs("ウィンドウが取れない（アクセシビリティ権限は？）\n", stderr); exit(1)
        }
        var pos = shot.origin
        var size = shot.size
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &pos)!)
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
        sleep(0.5)
        if let got = read(w), got.integral == shot.integral {
            print("窓を \(Int(shot.width))x\(Int(shot.height)) @ (\(Int(shot.minX)),\(Int(shot.minY))) に設置（\(attempt) 回目で確定）")
            return
        }
    }
    let got = frontWindow().flatMap(read)
    fputs("中止: 窓を録画枠に置けない（いま \(got.map { "\(Int($0.width))x\(Int($0.height)) @ (\(Int($0.minX)),\(Int($0.minY)))" } ?? "不明")）。\n"
        + "座標で叩く台本なので、ここがずれると後ろが全部外れる。\n", stderr)
    exit(1)
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
    let term = ProcessInfo.processInfo.environment["MREDITOR_DEMO_TERM"] ?? "株式会社ミライト・ワン"
    let t0 = Date()
    func mark(_ name: String) {
        print("\(name) \(String(format: "%.2f", Date().timeIntervalSince(t0)))")
        fflush(stdout)
    }

    // ── 1 幕: 開いた状態から始める ──────────────────────────────────
    // **開くダイアログは映さない。** ⌘O → ⌘⇧G の経路は Finder のパス欄に
    // 手元のディレクトリがそのまま出るので、公開する画には入れない。
    // ファイルは record_csv_demo.sh が録画開始前に開いておく。
    sleep(1.4)                                   // 開いた画を見せる
    mark("READY_AT")

    moveMouse(CGPoint(x: 800, y: 420)); sleep(0.3)
    scroll(lines: 90, steps: 35)                 // Shift-JIS の日本語が化けずに出ている
    sleep(0.8)

    // ── 2 幕: 絞り込む ──────────────────────────────────────────────
    // 1.06GB を Shift-JIS のまま全走査する。**2.4 秒**（実測。2026-09-05 に
    // 26.2 秒から直した ── 1 行ずつ String へデコードするのをやめ、語のほうを
    // Shift-JIS に変換してバイトのまま探すようにした）。
    tap("f", .maskCommand);            sleep(0.9)
    paste(term);                       sleep(0.6)
    tap(kReturn)
    mark("RETURN_AT")

    sleep(4.0)                                   // 走査が終わる（実測 2.4 秒）
    mark("FILTERED_AT")
    sleep(3.0)                                   // 581 万行から残った 13 行を読む

    // ── 3 幕: 絞り込みを解いて直す ────────────────────────────────────
    // **絞り込み中は編集できない**（一致行だけの非連続な並びなので入力を切っている）。
    // 隠さずそのまま見せる。解除すると、見ていた一致行が最上行に来る。
    tap(kEscape);                      sleep(1.6)
    mark("UNFILTERED_AT")

    // クリックしてキャレットを置き、⌘→ で行末へ。CSV の行末に 1 列足すのは
    // 「加工」として素直で、値の途中に割り込ませるより読める。
    click(firstRow);                   sleep(1.0)
    tap(kRight, .maskCommand);         sleep(1.2)   // 行末へ（横に流れる）
    paste(",\"MrEditor で追記\"", replacing: false); sleep(2.0)
    mark("EDITED_AT")

    // ── 4 幕: 保存する ──────────────────────────────────────────────
    tap("s", .maskCommand)
    mark("SAVE_AT")
    sleep(5.0)                                   // 1.06GB の書き出し
    mark("END_AT")
}

/// 録画前の下ごしらえ。サイドバーを畳むだけ。
func prep() {
    _ = activateOrDie()
    click(sidebarToggle)
    sleep(0.6)
    print("サイドバーを畳んだ")
}

/// 開いて絞り込むところまでやって、あとは黙って待つ。
/// 絞り込みが実際に何秒かかるかを、外から（画面を撮って）測るための足場。
func measure() {
    _ = activateOrDie()
    saveClipboard()
    defer { restoreClipboard() }
    let term = ProcessInfo.processInfo.environment["MREDITOR_DEMO_TERM"] ?? "東京都"
    let t0 = Date()
    sleep(0.8)
    openTheCsv()
    sleep(2.2)
    print("OPENED_AT \(String(format: "%.2f", Date().timeIntervalSince(t0)))")
    tap("f", .maskCommand);            sleep(0.9)
    paste(term);                       sleep(0.6)
    tap(kReturn)
    print("RETURN_AT \(String(format: "%.2f", Date().timeIntervalSince(t0)))")
    fflush(stdout)
    sleep(75.0)
    print("END_AT \(String(format: "%.2f", Date().timeIntervalSince(t0)))")
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
case "prep": prep()
case "measure": measure()
case "probe": probe()
default:
    fputs("使い方: csv_demo_driver <place|act|probe> <csv のパス>\n", stderr); exit(1)
}
