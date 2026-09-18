import XCTest
import AppKit
@testable import MrEditorCore

/// 簡易クリップボード履歴（B6）。永続化しないこと自体はテストできない（プロセスが
/// 生きている間の話でしかない）ので、ここで縛るのは記録の判定 ── 何を憶え、何を弾くか。
final class ClipboardHistoryTests: XCTestCase {
    private let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    func testRecordsPlainText() {
        let h = ClipboardHistory()
        h.record(types: [.string], text: "hello")
        XCTAssertEqual(h.entries.map(\.text), ["hello"])
    }

    func testNewestFirst() {
        let h = ClipboardHistory()
        h.record(types: [.string], text: "one")
        h.record(types: [.string], text: "two")
        XCTAssertEqual(h.entries.map(\.text), ["two", "one"])
    }

    /// 1Password 等がパスワードコピー時に立てるフラグ。無視すると
    /// 「パスワードが履歴に並ぶアプリ」になる ── 絶対に守る条件。
    func testSkipsConcealedType() {
        let h = ClipboardHistory()
        h.record(types: [.string, concealed], text: "s3cr3t")
        XCTAssertTrue(h.entries.isEmpty)
    }

    func testSkipsEmptyOrMissingText() {
        let h = ClipboardHistory()
        h.record(types: [.string], text: "")
        h.record(types: [.string], text: nil)
        XCTAssertTrue(h.entries.isEmpty)
    }

    /// 同じ内容が連続でコピーされても（ポーリングの取りこぼし等）1件のまま。
    func testConsecutiveDuplicateDoesNotGrowList() {
        let h = ClipboardHistory()
        h.record(types: [.string], text: "same")
        h.record(types: [.string], text: "same")
        XCTAssertEqual(h.entries.count, 1)
    }

    /// 同じ内容でも間に別のものを挟めば、別の1件として残る（コピーし直した実感を消さない）。
    func testSameTextAfterSomethingElseIsRecordedAgain() {
        let h = ClipboardHistory()
        h.record(types: [.string], text: "a")
        h.record(types: [.string], text: "b")
        h.record(types: [.string], text: "a")
        XCTAssertEqual(h.entries.map(\.text), ["a", "b", "a"])
    }

    func testOldestIsDroppedPastLimit() {
        let h = ClipboardHistory()
        h.limit = 3
        for s in ["1", "2", "3", "4"] { h.record(types: [.string], text: s) }
        XCTAssertEqual(h.entries.map(\.text), ["4", "3", "2"])
    }

    func testOnChangeFiresOnRecordAndClear() {
        let h = ClipboardHistory()
        var hits = 0
        h.onChange = { hits += 1 }
        h.record(types: [.string], text: "x")
        XCTAssertEqual(hits, 1)
        h.clear()
        XCTAssertEqual(hits, 2)
        XCTAssertTrue(h.entries.isEmpty)
    }

    /// 弾かれた記録は onChange を鳴らさない（メニューを無駄に組み直させない）。
    func testOnChangeDoesNotFireWhenSkipped() {
        let h = ClipboardHistory()
        var hits = 0
        h.onChange = { hits += 1 }
        h.record(types: [.string, concealed], text: "s3cr3t")
        h.record(types: [.string], text: "")
        XCTAssertEqual(hits, 0)
    }

    func testClearOnEmptyHistoryDoesNotFireOnChange() {
        let h = ClipboardHistory()
        var hits = 0
        h.onChange = { hits += 1 }
        h.clear()
        XCTAssertEqual(hits, 0)
    }

    // MARK: - tick（実際の NSPasteboard 経由）

    /// `tick` は changeCount が動いたときだけ pasteboard を読む。
    func testTickOnlyRecordsWhenChangeCountMoves() {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer {
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }

        let h = ClipboardHistory()
        h.tick()
        XCTAssertTrue(h.entries.isEmpty)   // 何もコピーしていない

        pb.clearContents()
        pb.setString("picked up by tick", forType: .string)
        h.tick()
        XCTAssertEqual(h.entries.map(\.text), ["picked up by tick"])

        h.tick()
        XCTAssertEqual(h.entries.count, 1)   // 変化が無ければ増えない
    }

    // MARK: - メニューの見出し（AppDelegate.clipboardMenuTitle）

    func testMenuTitleReplacesNewlinesWithAGlyph() {
        XCTAssertEqual(AppDelegate.clipboardMenuTitle(for: "a\nb"), "a⏎ b")
    }

    func testMenuTitleTruncatesLongText() {
        let long = String(repeating: "x", count: 100)
        let title = AppDelegate.clipboardMenuTitle(for: long, maxLength: 20)
        XCTAssertEqual(title.count, 21) // 20 文字 + "…"
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testMenuTitleKeepsShortTextAsIs() {
        XCTAssertEqual(AppDelegate.clipboardMenuTitle(for: "short"), "short")
    }
}
