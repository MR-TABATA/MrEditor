import XCTest
import AppKit
@testable import MrEditor

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
}
