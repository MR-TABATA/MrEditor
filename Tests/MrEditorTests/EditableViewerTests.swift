import XCTest
import AppKit
@testable import MrEditor
@testable import MrEditorCore

/// 小ファイル編集ペイン（NSTextView バック）の文字コード指定・EOL 追従を検証する。
final class EditableViewerTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-ev-\(UUID().uuidString).txt")
    }

    // MARK: エンコード指定で開き直す

    /// Shift-JIS で書いたファイルを UTF-8 と誤って開いても、指定再オープンで正しく読める。
    func testReopenWithEncodingFixesDecode() throws {
        let text = "日本語のログ\nエラー発生"
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try text.data(using: .shiftJIS)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url, forcedEncoding: .utf8))   // わざと誤ったエンコードで開く
        XCTAssertNotEqual(v._testText, text)                    // 文字化けしている

        XCTAssertTrue(v.reopen(withEncoding: .shiftJIS))        // 正しいエンコードで開き直す
        XCTAssertEqual(v._testEncoding, .shiftJIS)
        XCTAssertEqual(v._testText, text)                       // 正しく読める
    }

    func testReopenWithoutFileFails() {
        let v = EditableViewer()
        v.newDocument()                                         // 未保存＝fileURL なし
        XCTAssertFalse(v.reopen(withEncoding: .shiftJIS))
    }

    // MARK: 保存エンコードの変更（変換は次の保存で反映）

    /// 保存エンコードを Shift-JIS に変えると dirty になり、保存でディスク実体が Shift-JIS になる。
    func testSetSaveEncodingThenSaveReencodes() throws {
        let text = "変換テスト\n二行目"
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try text.data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        XCTAssertEqual(v.currentSaveEncoding, .utf8)

        v.setSaveEncoding(.shiftJIS)                            // 変換は「予約」だけ
        XCTAssertEqual(v.currentSaveEncoding, .shiftJIS)
        XCTAssertTrue(v.isDirty)                                // 保存すべき変更が生じた

        XCTAssertTrue(v._testWrite(to: url))                    // ここで初めて書き出し（＝変換）
        let saved = try Data(contentsOf: url)
        XCTAssertEqual(saved, text.data(using: .shiftJIS))      // 実体が Shift-JIS
    }

    // MARK: EOL 追従（保存時に全文をファイルの EOL へ揃える）

    /// CRLF ファイルを編集して保存すると、NSTextView が入れた LF も CRLF に揃う。
    func testSavePreservesCRLF() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "a\r\nb\r\nc".data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        XCTAssertEqual(v._testLineEnding, .crlf)
        v._testSetText("x\ny\nz")                               // LF で編集した状態を模す
        XCTAssertTrue(v._testWrite(to: url))

        let saved = try Data(contentsOf: url)
        XCTAssertEqual(saved, "x\r\ny\r\nz".data(using: .utf8)) // 全行 CRLF
    }

    // MARK: 構造化表示は表示だけの変換（保存で中身を壊さない）

    /// 構造化表示（CSV 桁揃え）中に保存しても、書き出すのは整形後の見た目ではなく元の CSV。
    func testSaveWhileStructuredWritesOriginalCSV() throws {
        let text = "name,age\nAlice,30\nBob,7\n"
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try text.data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        v.setStructuredMode(.csv)                    // 列に桁揃えして表示
        XCTAssertEqual(v.structuredMode, .csv)
        XCTAssertFalse(v.canEdit)                    // 構造化中は読み取り専用

        XCTAssertTrue(v._testWrite(to: url))         // close→保存 等で write() が呼ばれても…
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(saved, text)                  // …元の CSV のまま
        XCTAssertFalse(saved.contains("│"))          // 区切り記号が混入しない
    }

    /// 構造化表示をオフにすると編集可へ戻り、本文も元に復元される。
    func testExitStructuredRestoresText() throws {
        let text = "name,age\nAlice,30\n"
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try text.data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        v.setStructuredMode(.csv)
        XCTAssertNotEqual(v._testText, text)         // 表示は整形後
        v.setStructuredMode(nil)
        XCTAssertNil(v.structuredMode)
        XCTAssertTrue(v.canEdit)
        XCTAssertEqual(v._testText, text)            // 元の本文に復元
    }

    // MARK: 印刷（プリントダイアログの「PDF として保存」が PDF 出力を兼ねる）

    /// 小ファイルの編集ペインは印刷できる。巨大ファイルのビューアは印刷できない
    /// （8,600 万行＝数百万ページになるため、メニューを無効化する根拠）。
    func testPrintOnlyAvailableForSmallFilePane() {
        XCTAssertTrue(EditableViewer().canPrint)

        let big = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertFalse(big.canPrint)
    }
}
