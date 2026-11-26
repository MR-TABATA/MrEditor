import XCTest
import AppKit
@testable import MrEditorCore

/// 分離した濁点・半濁点（「か」＋U+3099 など）を、合成済みの 1 文字に直す変換。
///
/// **比較は必ず `unicodeScalars` で行う。** Swift の `String` の `==` は正規等価で比べるので、
/// 「か＋U+3099」と「が」は等しいと判定される。`XCTAssertEqual(結果, "が")` では、変換していなくても通ってしまう。
final class DakutenComposeTests: XCTestCase {
    private func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map { $0.value } }

    private func compose(_ s: String) -> String? { TextTransform.composeDakuten.apply(s) }

    // MARK: 合成する（受け入れ基準）

    func testKaDakutenBecomesGa() {
        XCTAssertEqual(scalars(compose("か\u{3099}")!), [0x304C])        // が
    }

    func testHaHandakutenBecomesPa() {
        XCTAssertEqual(scalars(compose("は\u{309A}")!), [0x3071])        // ぱ
    }

    func testOtherKanaThatComposeToOneScalar() {
        XCTAssertEqual(scalars(compose("う\u{3099}")!), [0x3094])        // ゔ
        XCTAssertEqual(scalars(compose("ウ\u{3099}")!), [0x30F4])        // ヴ
        XCTAssertEqual(scalars(compose("ワ\u{3099}")!), [0x30F7])        // ヷ
        XCTAssertEqual(scalars(compose("ゝ\u{3099}")!), [0x309E])        // ゞ
        XCTAssertEqual(scalars(compose("ヽ\u{3099}")!), [0x30FE])        // ヾ
    }

    func testSentenceWithSeveralDecomposedKana() {
        let src = "ファイル名: か\u{3099}き\u{3099}く\u{3099}\nへ\u{309A}ー\u{30B7}\u{3099}"
        let want = "ファイル名: がぎぐ\nぺー\u{30B8}"
        XCTAssertEqual(scalars(compose(src)!), scalars(want))
    }

    // MARK: 合成しない（変えてはいけないもの）

    func testMarkAfterNonComposableBaseIsLeftAlone() {
        let src = "あ\u{3099}"                                          // 「あ」＋濁点は合成できない
        XCTAssertEqual(scalars(compose(src)!), scalars(src))
        let latin = "A\u{3099}"
        XCTAssertEqual(scalars(compose(latin)!), scalars(latin))
    }

    func testLoneMarkAtStartAndAfterNewlineIsLeftAlone() {
        let src = "\u{3099}あ\n\u{309A}い"
        XCTAssertEqual(scalars(compose(src)!), scalars(src))
    }

    func testDoubleMarkOnlyComposesTheFirst() {
        // か＋U+3099＋U+3099 → が＋U+3099（2 つ目は、合成済みの「が」とは合成できないので残る）
        XCTAssertEqual(scalars(compose("か\u{3099}\u{3099}")!), [0x304C, 0x3099])
    }

    func testStringWithoutMarksIsUnchanged() {
        let src = "Hello, 日本語のテキスト\nabc 123"
        XCTAssertEqual(scalars(compose(src)!), scalars(src))
        XCTAssertEqual(scalars(compose("")!), [])
    }

    func testAlreadyComposedKanaIsUnchanged() {
        let src = "がぎぐ ぱぴぷ ヴ"
        XCTAssertEqual(scalars(compose(src)!), scalars(src))
    }

    /// 全体の NFC を掛けると変わってしまう文字を、変えない（濁点と無関係の文字を黙って書き換えない）。
    func testCharactersThatFullNFCWouldChangeAreLeftAlone() {
        for cp: UInt32 in [0xFA10, 0x212B, 0x2126] {                    // 互換漢字（塚）・Å 記号・Ω 記号
            let s = String(Unicode.Scalar(cp)!)
            XCTAssertEqual(scalars(compose(s)!), [cp], "U+\(String(cp, radix: 16, uppercase: true)) が変わった")
        }
    }

    func testHalfwidthKanaIsLeftAlone() {
        let a = "ｶ\u{FF9E}"                                             // 半角「ｶﾞ」（半角濁点 U+FF9E）
        XCTAssertEqual(scalars(compose(a)!), scalars(a))
        let b = "ｶ\u{3099}"                                             // 半角「ｶ」＋結合濁点は合成できない
        XCTAssertEqual(scalars(compose(b)!), scalars(b))
    }

    // MARK: 「変化なし」の判定（== では拾えない）

    /// 変換の結果が、`unicodeScalars` でも元と同じなら「変化なし」。分離形→合成形は「変化あり」。
    func testScalarEqualityDistinguishesDecomposedFromComposed() {
        let decomposed = "か\u{3099}"
        let composed = compose(decomposed)!
        XCTAssertTrue(composed == decomposed, "前提: Swift の == は正規等価で、両者を等しいと判定する")
        XCTAssertFalse(composed.unicodeScalars.elementsEqual(decomposed.unicodeScalars))
        XCTAssertTrue(String.scalarsEqual(composed, composed))
        XCTAssertFalse(String.scalarsEqual(composed, decomposed))
    }

    // MARK: ビューアで実際に本文が置き換わる

    /// PieceTable 版（巨大でない通常の編集面）。選択はバイト単位。
    func testPieceTableViewerReplacesSelectionAndUndoRestores() {
        let src = "か\u{3099}き\u{3099}"                                // 6+6 = 12 バイト
        let v = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v._testLoad(Array(src.utf8))
        v._testSelect(0..<12)
        v.applyTextTransform(.composeDakuten)
        XCTAssertEqual(scalars(v._testDocString), [0x304C, 0x304E])     // がぎ
        v._testUndo()
        XCTAssertEqual(scalars(v._testDocString), scalars(src))         // 元の分離形に戻る（1 回で）
    }

    func testPieceTableViewerNoChangeDoesNotPushUndo() {
        let src = "がぎ"                                                // すでに合成済み
        let v = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v._testLoad(Array(src.utf8))
        v._testSelect(0..<6)
        v.applyTextTransform(.composeDakuten)
        XCTAssertEqual(scalars(v._testDocString), scalars(src))
        v._testUndo()                                                   // 積まれていなければ、何も戻らない
        XCTAssertEqual(scalars(v._testDocString), scalars(src))
    }

    /// NSTextView 版（小さなファイル・新規タブ）。選択は UTF-16 単位。
    func testEditableViewerReplacesSelection() {
        let v = EditableViewer()
        v._testSetText("か\u{3099}き\u{3099}x")
        v._testSelect(NSRange(location: 0, length: 4))                  // 「か゛き゛」（UTF-16 で 4 単位）
        v.applyTextTransform(.composeDakuten)
        XCTAssertEqual(scalars(v._testText), [0x304C, 0x304E, 0x78])    // がぎx
        XCTAssertTrue(v.isDirty)
    }

    func testEditableViewerNoSelectionIsNoOp() {
        let v = EditableViewer()
        let src = "か\u{3099}"
        v._testSetText(src)
        v._testSelect(NSRange(location: 0, length: 0))
        v.applyTextTransform(.composeDakuten)
        XCTAssertEqual(scalars(v._testText), scalars(src))
    }

    // MARK: 並びが想定外のとき（MCR 指摘 1）

    func testUnusualMarkSequences() {
        // か＋U+3099＋U+309A → が＋U+309A（半濁点は、合成済みの「が」とは合成できないので残る）
        XCTAssertEqual(scalars(compose("か\u{3099}\u{309A}")!), [0x304C, 0x309A])
        // は＋U+309A＋U+3099 → ぱ＋U+3099（同じく、濁点が残る）
        XCTAssertEqual(scalars(compose("は\u{309A}\u{3099}")!), [0x3071, 0x3099])
        // 間に別の結合記号（U+0301）が入ると、直前の 1 文字が仮名ではないので、合成しない（そのまま）
        let withAcute = "か\u{0301}\u{3099}"
        XCTAssertEqual(scalars(compose(withAcute)!), scalars(withAcute))
        // 行をまたいだ濁点は、前の行の仮名とは合成しない
        let acrossLines = "か\n\u{3099}"
        XCTAssertEqual(scalars(compose(acrossLines)!), scalars(acrossLines))
    }

    // MARK: メニューの登録と文言（MCR 指摘 3）

    /// 新しい変換が書式メニューのグループに入っていること、日本語・英語の両方でタイトルが登録されていること。
    /// 登録漏れ・綴り違いだと、メニューにキー名（menu.format.composeDakuten）がそのまま出る。
    /// （メニューへの組み込み自体〔`AppDelegate` が `dakutenGroup` を並べること〕は、ここでは確かめない。）
    func testMenuGroupAndTitlesInBothLanguages() throws {
        XCTAssertEqual(TextTransform.dakutenGroup, [.composeDakuten])
        let key = TextTransform.composeDakuten.localizationKey
        XCTAssertEqual(key, "menu.format.composeDakuten")
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MrEditorCore/Resources")
        for lang in ["ja", "en"] {
            let url = resources.appendingPathComponent("\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(lang): .strings を読めない")
            let title = try XCTUnwrap(table[key], "\(lang): \(key) が登録されていない")
            XCTAssertFalse(title.isEmpty, "\(lang): タイトルが空")
            XCTAssertNotEqual(title, key, "\(lang): タイトルがキー名のまま")
        }
    }

    // MARK: 選択の端で濁点が切れるとき（MCR 指摘 4）

    func testSelectionEndingBetweenBaseAndMarkDoesNothing() {
        let src = "か\u{3099}"                                          // 「か」3 バイト＋U+3099 3 バイト
        let v = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v._testLoad(Array(src.utf8))
        v._testSelect(0..<3)                                            // 「か」だけ（濁点は選択の外）
        v.applyTextTransform(.composeDakuten)
        XCTAssertEqual(scalars(v._testDocString), scalars(src))
        v._testSelect(3..<6)                                            // 濁点だけ（前の「か」は選択の外）
        v.applyTextTransform(.composeDakuten)
        XCTAssertEqual(scalars(v._testDocString), scalars(src))
        v._testUndo()                                                   // 何も積まれていない（履歴が増えていない）
        XCTAssertEqual(scalars(v._testDocString), scalars(src))
    }

    /// NSTextView 版（実測・一定）: 「か」だけを選ぶと、選択は「か」だけで、濁点は外れる（変換は何も起きない）。
    /// 濁点だけを選ぶと、選択は文字（書記素）の境界に広がって「か＋U+3099」の 2 文字分になり、合成される。
    /// どちらも、本文は壊れない。
    func testEditableViewerSelectionAtTheEdgeOfBaseAndMark() {
        let baseOnly = EditableViewer()
        baseOnly._testSetText("か\u{3099}")
        baseOnly._testSelect(NSRange(location: 0, length: 1))
        baseOnly.applyTextTransform(.composeDakuten)
        XCTAssertEqual(scalars(baseOnly._testText), [0x304B, 0x3099])      // 変わらない

        let markOnly = EditableViewer()
        markOnly._testSetText("か\u{3099}")
        markOnly._testSelect(NSRange(location: 1, length: 1))
        markOnly.applyTextTransform(.composeDakuten)
        XCTAssertEqual(scalars(markOnly._testText), [0x304C])              // 選択が広がって合成される
    }

    // MARK: 検出（件数。ステータスバーと貼り付けの通知が使う。変換と同じ判定を共有する）

    func testCountDecomposedKana() {
        XCTAssertEqual(DecomposedKana.count(in: ""), 0)
        XCTAssertEqual(DecomposedKana.count(in: "か\u{3099}"), 1)
        XCTAssertEqual(DecomposedKana.count(in: "か\u{3099}は\u{309A}ウ\u{3099}"), 3)
        // 数えないもの
        XCTAssertEqual(DecomposedKana.count(in: "がぎぐ ぱぴぷ ヴ"), 0)     // 合成済み
        XCTAssertEqual(DecomposedKana.count(in: "あ\u{3099}"), 0)          // 合成できない組み合わせ
        XCTAssertEqual(DecomposedKana.count(in: "\u{3099}あ\n\u{309A}"), 0) // 孤立した濁点・半濁点
        XCTAssertEqual(DecomposedKana.count(in: "ｶ\u{FF9E}ｶ\u{3099}"), 0)   // 半角
        XCTAssertEqual(DecomposedKana.count(in: "\u{FA10}\u{212B}\u{2126}"), 0)
        XCTAssertEqual(DecomposedKana.count(in: "か\u{3099}\u{3099}"), 1)  // 2 つ目の記号は数えない
    }

    /// 件数は、変換が実際に合成する数と一致する。変換のあとは 0 件になる（判定が 2 か所でずれていない）。
    func testCountMatchesWhatComposeDoes() {
        let samples = [
            "", "abc", "か\u{3099}", "か\u{3099}\u{3099}", "か\u{3099}\u{309A}", "は\u{309A}\u{3099}",
            "あ\u{3099}", "\u{3099}", "か\u{0301}\u{3099}", "か\n\u{3099}", "ｶ\u{3099}",
            "ファイル名: か\u{3099}き\u{3099}く\u{3099}\nへ\u{309A}ー\u{30B7}\u{3099}",
            "ウ\u{3099}ワ\u{3099}ゝ\u{3099}ヽ\u{3099}", "\u{FA10}\u{212B}か\u{3099}",
        ]
        for s in samples {
            let composed = compose(s)!
            XCTAssertEqual(DecomposedKana.count(in: s), s.unicodeScalars.count - composed.unicodeScalars.count, "件数と合成数がずれた: \(scalars(s))")
            XCTAssertEqual(DecomposedKana.count(in: composed), 0, "変換のあとも残っている: \(scalars(s))")
        }
    }

    // MARK: ステータスバーに出す件数（ViewerState）

    func testEditableViewerStateReportsDecomposedCount() {
        let v = EditableViewer()
        var last: ViewerState?
        v.onStateChange = { last = $0 }
        v._testSetText("か\u{3099}き\u{3099}x")
        v._testSelect(NSRange(location: 4, length: 1))                  // "x"
        v.applyTextTransform(.uppercase)                                // 状態を送らせる
        XCTAssertEqual(last?.decomposedKanaCount, 2)
        v._testSelect(NSRange(location: 0, length: 4))
        v.applyTextTransform(.composeDakuten)
        XCTAssertEqual(last?.decomposedKanaCount, 0, "直したあとは 0 件")
    }

    // MARK: 貼り付けの通知（本文は書き換えない）

    /// NSTextView 版。貼り付け（とドラッグでの文字列の挿入）の入口の `readSelection(from:type:)` で拾う。
    /// システムのクリップボードを汚さないよう、専用のペーストボードで試す。
    func testPasteIntoTextViewNotifiesAndDoesNotRewrite() {
        let tv = EditorTextView()
        var notified: Int?
        tv.onDecomposedPaste = { notified = $0 }
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("か\u{3099}き\u{3099}", forType: .string)
        XCTAssertTrue(tv.readSelection(from: pb, type: .string))
        XCTAssertEqual(notified, 2)
        XCTAssertEqual(scalars(tv.string), [0x304B, 0x3099, 0x304D, 0x3099], "貼った本文を書き換えてはいけない")

        // 合成済み・濁点のない文字列では、通知しない。
        notified = nil
        pb.clearContents()
        pb.setString("がぎ abc", forType: .string)
        XCTAssertTrue(tv.readSelection(from: pb, type: .string))
        XCTAssertNil(notified)
    }

    /// PieceTable 版（巨大ファイルの編集面）。
    func testPasteIntoPieceTableViewerNotifiesAndDoesNotRewrite() {
        let v = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v._testLoad(Array("abc".utf8))
        v._testSetCaret(3)
        var notified: Int?
        v.onDecomposedPaste = { notified = $0 }
        v.paste(text: "か\u{3099}は\u{309A}")
        XCTAssertEqual(notified, 2)
        XCTAssertEqual(scalars(v._testDocString), scalars("abcか\u{3099}は\u{309A}"), "貼った本文を書き換えてはいけない")

        notified = nil
        v.paste(text: "がぱ")
        XCTAssertNil(notified)
    }

    // MARK: 表と NFC の一致（MCR 指摘: 都度 NFC をやめて表にした）

    /// 判定は表から引く。直接 NFC をかけた結果と、仮名の全範囲×2 つの記号で一致する（範囲の外の文字は、合成しない）。
    func testComposedTableMatchesNFCForEveryCombination() {
        for base in UInt32(0x3041)...UInt32(0x30FF) {
            for mark in [UInt32(0x3099), UInt32(0x309A)] {
                let b = Unicode.Scalar(base)!, m = Unicode.Scalar(mark)!
                XCTAssertEqual(TextTransform.composedKana(b, mark: m), TextTransform.composedByNFC(b, mark: m),
                               "U+\(String(base, radix: 16, uppercase: true)) + U+\(String(mark, radix: 16, uppercase: true))")
            }
        }
        // 範囲の外（ラテン・仮名の手前・仮名の先・半角カナ）は、合成しない。
        for base: UInt32 in [0x41, 0x3040, 0x3100, 0xFF76] {
            for mark in [UInt32(0x3099), UInt32(0x309A)] {
                XCTAssertNil(TextTransform.composedKana(Unicode.Scalar(base)!, mark: Unicode.Scalar(mark)!))
            }
        }
    }

    // MARK: 編集できない表示では、貼り付けの通知を出さない（MCR 指摘）

    func testEditableViewerDoesNotNotifyWhenItCannotEdit() {
        let v = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v._testSetText("a,b\n1,2\n")
        var notified: [Int] = []
        v.onDecomposedPaste = { notified.append($0) }

        XCTAssertTrue(v.canEdit)
        v._testNotifyDecomposedPaste(2)
        XCTAssertEqual(notified, [2], "編集できるときは、通知が届く")

        v.setStructuredMode(.csv)                                       // 整形表示＝読み取り専用の見た目
        XCTAssertFalse(v.canEdit)
        v._testNotifyDecomposedPaste(5)
        XCTAssertEqual(notified, [2], "編集できない表示では、通知が出ない")
    }
}

/// 貼り付けの帯（`MainWindowController.dakutenBanner`）の出入り。
final class DakutenBannerTests: XCTestCase {
    private func makeController() -> (MainWindowController, EditableViewer, EditableViewer) {
        let a = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let b = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let controller = MainWindowController()
        _ = controller.window
        controller.viewers = [a, b]
        controller.wire(a)
        controller.wire(b)
        controller.activate(0)
        return (controller, a, b)
    }

    private func state(decomposed: Int?) -> ViewerState {
        ViewerState(encodingName: "UTF-8", lineCount: 1, lineCountIsExact: true, fileSize: 0, indexProgress: 1,
                    caret: nil, charCount: nil, decomposedKanaCount: decomposed)
    }

    func testBannerAppearsOnPasteInTheActivePane() {
        let (controller, a, _) = makeController()
        XCTAssertTrue(controller.dakutenBanner.isHidden, "最初は出ない")
        a.onDecomposedPaste?(3)
        XCTAssertFalse(controller.dakutenBanner.isHidden)
    }

    /// 直して 0 件になったら、帯は消える。件数が残っている間と、数えない面（nil）では消えない。
    func testBannerDisappearsWhenCountReachesZero() {
        let (controller, a, _) = makeController()
        a.onDecomposedPaste?(3)
        a.onStateChange?(state(decomposed: 2))
        XCTAssertFalse(controller.dakutenBanner.isHidden, "まだ残っている間は、出たまま")
        a.onStateChange?(state(decomposed: nil))
        XCTAssertFalse(controller.dakutenBanner.isHidden, "数えない面（nil）では、触らない")
        a.onStateChange?(state(decomposed: 0))
        XCTAssertTrue(controller.dakutenBanner.isHidden, "0 件になったら、消える")
    }

    func testBannerIsHiddenWhenSwitchingTabs() {
        let (controller, a, _) = makeController()
        a.onDecomposedPaste?(3)
        XCTAssertFalse(controller.dakutenBanner.isHidden)
        controller.activate(1)
        XCTAssertTrue(controller.dakutenBanner.isHidden, "別のタブへ切り替えたら、持ち越さない")
    }

    func testPasteInAnInactivePaneDoesNotShowTheBanner() {
        let (controller, _, b) = makeController()                        // アクティブは a（0 番）
        b.onDecomposedPaste?(4)
        XCTAssertTrue(controller.dakutenBanner.isHidden, "見えていないペインの貼り付けで、いまの画面に帯を出さない")
    }
}
