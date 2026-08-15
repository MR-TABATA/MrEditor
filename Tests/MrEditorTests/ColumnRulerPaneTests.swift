import XCTest
import AppKit
@testable import MrEditorCore

/// 桁ルーラーが**両ペインで同じように振る舞う**こと。
///
/// 小ファイル（`NSTextView`）と巨大ファイル（自前描画）は仕組みがまったく違うので、
/// 片方だけ直して満足しやすい。ここは対になる検証を並べて置き、
/// 「片方にしか無い」状態でテストが落ちるようにしてある。
final class ColumnRulerPaneTests: XCTestCase {

    private func smallPane(_ text: String = "1234567890abcdefghij\n") -> EditableViewer {
        let v = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v._testSetText(text)
        return v
    }

    private func largePane(_ text: String = "1234567890abcdefghij\n") -> PieceTableViewer {
        let v = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v._testLoad(Array(text.utf8))
        return v
    }

    // MARK: - 両ペインとも対応している

    func testBothPanesSupportColumnRuler() {
        XCTAssertTrue(smallPane().supportsColumnRuler)
        XCTAssertTrue(largePane().supportsColumnRuler)
    }

    func testRulerIsHiddenByDefault() {
        XCTAssertFalse(smallPane().columnRulerVisible)
        XCTAssertFalse(largePane().columnRulerVisible)
    }

    func testToggleVisibility() {
        let small = smallPane(), large = largePane()
        small.setColumnRulerVisible(true)
        large.setColumnRulerVisible(true)
        XCTAssertTrue(small.columnRulerVisible)
        XCTAssertTrue(large.columnRulerVisible)
        small.setColumnRulerVisible(false)
        large.setColumnRulerVisible(false)
        XCTAssertFalse(small.columnRulerVisible)
        XCTAssertFalse(large.columnRulerVisible)
    }

    // MARK: - 折り返しを切る（折り返すと 1 行が割れて桁が定まらない）

    func testShowingRulerDisablesWrapInSmallPane() {
        let v = smallPane()
        XCTAssertTrue(v._testWrapsText, "既定は折り返し")
        v.setColumnRulerVisible(true)
        XCTAssertFalse(v._testWrapsText, "ルーラーを出したら横スクロールへ切り替わる")
    }

    func testHidingRulerRestoresWrapInSmallPane() {
        let v = smallPane()
        v.setColumnRulerVisible(true)
        v.setColumnRulerVisible(false)
        XCTAssertTrue(v._testWrapsText, "しまったら元の折り返しに戻る")
    }

    func testShowingRulerDisablesWrapInLargePane() {
        let v = largePane()
        v.setColumnRulerVisible(true)
        XCTAssertFalse(v._testWrapEnabled)
    }

    /// 既に横スクロール（構造化表示中など）なら、しまうときに勝手に折り返しへ戻さない。
    func testHidingRulerDoesNotForceWrapWhenItWasAlreadyOff() {
        let v = largePane("a,b,c\n1,2,3\n")
        v.setStructuredMode(.csv)          // 構造化＝横スクロール固定
        XCTAssertFalse(v._testWrapEnabled)
        v.setColumnRulerVisible(true)
        v.setColumnRulerVisible(false)
        XCTAssertFalse(v._testWrapEnabled, "構造化の都合を壊さない")
    }

    /// ルーラーを出している間に環境設定で折り返しを入れても、目盛りと本文がズレないよう
    /// 折り返しは効かせない。**しまったときに新しい設定が反映される**。
    func testLineWrapSettingIsDeferredWhileRulerIsVisible() {
        let saved = AppSettings.lineWrap
        defer { AppSettings.lineWrap = saved }

        AppSettings.lineWrap = false
        let v = largePane()
        v.setColumnRulerVisible(true)

        AppSettings.lineWrap = true
        v.applyLineWrap()
        XCTAssertFalse(v._testWrapEnabled, "ルーラー中に折り返しが効いてしまっている")

        v.setColumnRulerVisible(false)
        XCTAssertTrue(v._testWrapEnabled, "しまったあとに新しい設定が反映されていない")
    }

    // MARK: - ガイドは桁の配列として両ペインに載る

    func testGuidesToggleInBothPanes() {
        let small = smallPane(), large = largePane()
        small._testToggleColumnGuide(9)
        large._testToggleColumnGuide(9)
        XCTAssertEqual(small._testColumnGuides, [9])
        XCTAssertEqual(large._testColumnGuides, [9])
        XCTAssertTrue(small.hasColumnGuides)
        XCTAssertTrue(large.hasColumnGuides)

        small._testToggleColumnGuide(9)
        large._testToggleColumnGuide(9)
        XCTAssertTrue(small._testColumnGuides.isEmpty)
        XCTAssertTrue(large._testColumnGuides.isEmpty)
    }

    func testGuidesStaySortedInBothPanes() {
        let small = smallPane(), large = largePane()
        for col in [15, 9, 40, 1] {
            small._testToggleColumnGuide(col)
            large._testToggleColumnGuide(col)
        }
        XCTAssertEqual(small._testColumnGuides, [1, 9, 15, 40])
        XCTAssertEqual(large._testColumnGuides, [1, 9, 15, 40])
    }

    func testClearGuidesInBothPanes() {
        let small = smallPane(), large = largePane()
        small._testToggleColumnGuide(9); large._testToggleColumnGuide(9)
        small.clearColumnGuides(); large.clearColumnGuides()
        XCTAssertFalse(small.hasColumnGuides)
        XCTAssertFalse(large.hasColumnGuides)
    }

    /// ガイドはルーラーを出していなくても保持される（しまってもまた出せば同じ場所にある）。
    func testGuidesSurviveHidingTheRuler() {
        let v = smallPane()
        v.setColumnRulerVisible(true)
        v._testToggleColumnGuide(9)
        v.setColumnRulerVisible(false)
        v.setColumnRulerVisible(true)
        XCTAssertEqual(v._testColumnGuides, [9])
    }

    // MARK: - 目盛りが本文と同じ場所から始まること
    //
    // ここが今回いちばん効いた検証。原点を「ガター幅＋コンテナ余白」と自分で足す式で書いたら、
    // 行番号ガターぶん右へずれた（実機のスクリーンショットで発覚）。式を書かず、本文の
    // 1 文字目が実際に描かれている x を AppKit に出させて突き合わせる。

    func testRulerOriginMatchesTextOriginInSmallPane() throws {
        let v = smallPane()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = v
        v.setColumnRulerVisible(true)
        v.layoutSubtreeIfNeeded()

        let glyphX = try XCTUnwrap(v._testFirstGlyphX)
        XCTAssertEqual(v._testRulerColumnOneX, glyphX, accuracy: 0.5,
                       "1 桁目の目盛りが本文の 1 文字目と同じ x から始まっていない")
    }

    func testRulerOriginMatchesTextOriginInLargePane() {
        let v = largePane()
        v.setColumnRulerVisible(true)
        XCTAssertEqual(v._testRulerColumnOneX, v._testFirstGlyphX, accuracy: 0.5)
    }

    /// 行番号ガターを消しても原点はズレない（ガター幅を自分で足していると、ここで壊れる）。
    func testRulerOriginFollowsLineNumberGutterVisibility() throws {
        let v = smallPane()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = v
        v.setColumnRulerVisible(true)
        v.layoutSubtreeIfNeeded()

        let before = try XCTUnwrap(v._testFirstGlyphX)
        XCTAssertEqual(v._testRulerColumnOneX, before, accuracy: 0.5)

        let saved = AppSettings.showLineNumbers
        defer { AppSettings.showLineNumbers = saved; v.applyDisplaySettings() }
        AppSettings.showLineNumbers = !saved
        v.applyDisplaySettings()
        v.layoutSubtreeIfNeeded()

        let after = try XCTUnwrap(v._testFirstGlyphX)
        XCTAssertEqual(v._testRulerColumnOneX, after, accuracy: 0.5,
                       "ガターの出し入れに原点が追従していない")
    }

    // MARK: - 掴んで動かす（C）
    //
    // ドラッグが無いと 1 桁ずらすのに「消して置き直す」になる（B の実地で分かったこと）。

    func testDragMovesGuideInBothPanes() {
        let small = smallPane(), large = largePane()
        small._testToggleColumnGuide(9); large._testToggleColumnGuide(9)
        XCTAssertTrue(small._testMoveColumnGuide(9, to: 10))
        XCTAssertTrue(large._testMoveColumnGuide(9, to: 10))
        XCTAssertEqual(small._testColumnGuides, [10])
        XCTAssertEqual(large._testColumnGuides, [10])
    }

    func testDragOntoAnotherGuideIsRefusedInBothPanes() {
        let small = smallPane(), large = largePane()
        for col in [9, 15] { small._testToggleColumnGuide(col); large._testToggleColumnGuide(col) }
        XCTAssertFalse(small._testMoveColumnGuide(9, to: 15))
        XCTAssertFalse(large._testMoveColumnGuide(9, to: 15))
        XCTAssertEqual(small._testColumnGuides, [9, 15])
        XCTAssertEqual(large._testColumnGuides, [9, 15])
    }

    // MARK: - 数値で打つ（C）

    func testSetColumnGuidesReplacesTheWholeDefinition() {
        let small = smallPane(), large = largePane()
        small._testToggleColumnGuide(4); large._testToggleColumnGuide(4)
        small.setColumnGuides([9, 15]); large.setColumnGuides([9, 15])
        XCTAssertEqual(small.columnGuideColumns, [9, 15])
        XCTAssertEqual(large.columnGuideColumns, [9, 15])
        small.setColumnGuides([]); large.setColumnGuides([])
        XCTAssertFalse(small.hasColumnGuides)
        XCTAssertFalse(large.hasColumnGuides)
    }

    // MARK: - ファイルごとに覚える（C）

    private func tempFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-fields-\(UUID().uuidString).txt")
        try text.data(using: .utf8)!.write(to: url)
        return url
    }

    /// 開き直したら**さっきの項目定義のまま**。ルーラーも一緒に出す
    /// （縦線だけが黙って引かれていると、何の線か分からない）。
    func testFieldsAreRememberedPerFile() throws {
        let a = try tempFile("00012345TOKYO 20260815\n")
        let b = try tempFile("plain text\n")
        defer {
            AppSettings.setColumnGuides([], for: a)
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        let v = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertTrue(v.open(url: a))
        v.setColumnGuides([9, 15])

        XCTAssertTrue(v.open(url: b))
        XCTAssertTrue(v.columnGuideColumns.isEmpty, "別のファイルに前のファイルの定義を当てない")

        XCTAssertTrue(v.open(url: a))
        XCTAssertEqual(v.columnGuideColumns, [9, 15])
        XCTAssertTrue(v.columnRulerVisible, "覚えていた定義はルーラーごと戻す")
    }

    func testClearingGuidesForgetsThem() throws {
        let url = try tempFile("00012345TOKYO\n")
        defer { AppSettings.setColumnGuides([], for: url); try? FileManager.default.removeItem(at: url) }

        let v = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertTrue(v.open(url: url))
        v.setColumnGuides([9])
        v.clearColumnGuides()
        XCTAssertTrue(AppSettings.columnGuides(for: url).isEmpty)
    }

    // MARK: - 構造化表示の 5 つ目＝固定長（C）

    func testFixedWidthStructuredViewInSmallPane() {
        let v = smallPane("00012345TOKYO 20260815\n00000007OSAKA 20260101\n")
        v.setColumnGuides([9, 15])
        v.setStructuredMode(.fixedWidth)
        XCTAssertEqual(v.structuredMode, .fixedWidth)
        XCTAssertEqual(v.structuredColumnNames, ["1-8", "9-14", "15-22"])
        XCTAssertTrue(v._testText.contains("00012345 │ TOKYO │ 20260815"))
        XCTAssertFalse(v.canEdit, "構造化中は読み取り専用")

        v.setStructuredMode(nil)
        XCTAssertEqual(v._testText, "00012345TOKYO 20260815\n00000007OSAKA 20260101\n", "元の本文に戻る")
    }

    func testFixedWidthStructuredViewInLargePane() {
        let v = largePane("00012345TOKYO 20260815\n00000007OSAKA 20260101\n")
        v.setColumnGuides([9, 15])
        v.setStructuredMode(.fixedWidth)
        XCTAssertEqual(v.structuredMode, .fixedWidth)
        XCTAssertEqual(v.structuredColumnNames, ["1-8", "9-14", "15-22"])
    }

    /// 定義が無ければ固定長には入れない（区切り文字が無いのだから中身から列は割り出せない）。
    func testFixedWidthNeedsADefinitionInBothPanes() {
        let small = smallPane("00012345TOKYO\n"), large = largePane("00012345TOKYO\n")
        small.setStructuredMode(.fixedWidth)
        large.setStructuredMode(.fixedWidth)
        XCTAssertNil(small.structuredMode)
        XCTAssertNil(large.structuredMode)
    }

    /// 固定長で見ている最中に境界を動かしたら、列そのものが変わる＝組み直す。
    func testMovingAGuideRebuildsTheFixedWidthView() {
        let v = smallPane("00012345TOKYO 20260815\n")
        v.setColumnGuides([9, 15])
        v.setStructuredMode(.fixedWidth)
        v._testMoveColumnGuide(9, to: 8)
        XCTAssertEqual(v.structuredColumnNames, ["1-7", "8-14", "15-22"])
        XCTAssertTrue(v._testText.contains("0001234 │ 5TOKYO │ 20260815"))
    }

    /// 整形後の表示にガイド線を残さない（定義は**生の本文の桁**なので別の場所を指す）。
    /// 定義そのものは消さず、構造化を抜ければ戻る。
    func testGuidesAreHiddenWhileStructuredInBothPanes() {
        let small = smallPane("00012345TOKYO 20260815\n")
        let large = largePane("00012345TOKYO 20260815\n")
        for v in [small as DocumentPane, large as DocumentPane] { v.setColumnGuides([9, 15]) }
        XCTAssertFalse(small._testColumnGuidesHidden)
        XCTAssertFalse(large._testColumnGuidesHidden)

        small.setStructuredMode(.fixedWidth)
        large.setStructuredMode(.fixedWidth)
        XCTAssertTrue(small._testColumnGuidesHidden)
        XCTAssertTrue(large._testColumnGuidesHidden)
        XCTAssertEqual(small.columnGuideColumns, [9, 15], "描画だけ止める（定義は保つ）")
        XCTAssertEqual(large.columnGuideColumns, [9, 15])

        small.setStructuredMode(nil)
        large.setStructuredMode(nil)
        XCTAssertFalse(small._testColumnGuidesHidden)
        XCTAssertFalse(large._testColumnGuidesHidden)
    }

    // MARK: - 対応しないペイン

    func testDiffViewerDoesNotSupportColumnRuler() {
        let v = DiffViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertFalse(v.supportsColumnRuler)
        XCTAssertFalse(v.columnRulerVisible)
        v.setColumnRulerVisible(true)               // 既定実装の no-op（落ちないこと）
        XCTAssertFalse(v.columnRulerVisible)
    }
}
