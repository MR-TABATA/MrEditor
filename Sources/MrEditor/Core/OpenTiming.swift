import Foundation

/// 「ファイルを開いてから、最初の行が画面に出るまで」の実測。
///
/// README / LP に載せる数字の出どころ。憶測で書かないために計測できるようにしてある。
/// `MREDITOR_TIMING=1` を立てたときだけ動き、通常の起動では何もしない。
///
///   MREDITOR_TIMING=1 open -a .build/MrEditor.app --args ...
///   → 標準エラーに「first paint: NNN.N ms」を1回だけ出す
enum OpenTiming {

    static let enabled = ProcessInfo.processInfo.environment["MREDITOR_TIMING"] == "1"

    private static var startedAt: CFAbsoluteTime?
    private static var reported = false

    /// open(url:) の入口で呼ぶ。
    static func begin() {
        guard enabled else { return }
        startedAt = CFAbsoluteTimeGetCurrent()
        reported = false
    }

    /// 本文が実際に描かれたときに呼ぶ。最初の1回だけ報告する。
    static func firstPaint() {
        guard enabled, !reported, let t0 = startedAt else { return }
        reported = true
        log(String(format: "first paint: %.1f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
    }

    /// 背景の行索引が完成したときに呼ぶ。
    static func indexComplete(lines: Int) {
        guard enabled, let t0 = startedAt else { return }
        log(String(format: "index complete: %.2f s (%d lines)",
                   CFAbsoluteTimeGetCurrent() - t0, lines))
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
}
