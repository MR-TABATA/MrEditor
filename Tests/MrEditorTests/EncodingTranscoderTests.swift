import XCTest
@testable import MrEditor
@testable import MrEditorCore

/// エンコード変換保存の心臓部（行境界ストリーム変換）を検証する。
/// 原本を極端なスライス（1 バイトずつ＝マルチバイト分断）で流しても文字を割らないことが要点。
final class EncodingTranscoderTests: XCTestCase {
    /// バイト列を `sliceSize` ごとに区切って feed する変換を実行し、出力を連結して返す。
    private func transcode(_ input: Data, from s: DetectedEncoding, to t: DetectedEncoding,
                           sliceSize: Int) throws -> (Data, Bool) {
        let bytes = [UInt8](input)
        var out = Data()
        let lossy = try EncodingTranscoder.stream(
            from: s, to: t,
            feed: { sink in
                var i = 0
                while i < bytes.count {
                    let j = min(i + sliceSize, bytes.count)
                    try sink(bytes[i..<j])
                    i = j
                }
            },
            emit: { out.append($0) })
        return (out, lossy)
    }

    /// UTF-8 の日本語複数行を Shift-JIS へ。1 バイト刻みで流してもマルチバイトを割らない。
    func testUTF8ToShiftJISByteByByte() throws {
        let text = "日本語のログ\nエラー: 発生\n最終行"       // 末尾は改行なし
        let input = text.data(using: .utf8)!
        for slice in [1, 3, 7, 4096] {                       // 分断パターンを変えても不変
            let (out, lossy) = try transcode(input, from: .utf8, to: .shiftJIS, sliceSize: slice)
            XCTAssertFalse(lossy)
            XCTAssertEqual(String(data: out, encoding: .shiftJIS), text, "sliceSize=\(slice)")
        }
    }

    /// CRLF は変換後も CRLF のまま残る（0x0D 0x0A はどのエンコードでも ASCII）。
    func testCRLFPreservedAcrossConversion() throws {
        let input = "あ\r\nい\r\nう".data(using: .utf8)!
        let (out, _) = try transcode(input, from: .utf8, to: .eucJP, sliceSize: 2)
        XCTAssertEqual(String(data: out, encoding: .japaneseEUC), "あ\r\nい\r\nう")
        XCTAssertTrue([UInt8](out).contains(0x0D))            // CR が保たれている
    }

    /// Shift-JIS → UTF-8 の逆方向も往復一致する。
    func testShiftJISToUTF8RoundTrips() throws {
        let text = "テスト\n二行目"
        let input = text.data(using: .shiftJIS)!
        let (out, lossy) = try transcode(input, from: .shiftJIS, to: .utf8, sliceSize: 3)
        XCTAssertFalse(lossy)
        XCTAssertEqual(String(data: out, encoding: .utf8), text)
    }

    /// 目的エンコードで表現できない文字（絵文字→Shift-JIS）は lossy=true。
    func testUnrepresentableIsLossy() throws {
        let input = "hello 😀 world".data(using: .utf8)!
        let (_, lossy) = try transcode(input, from: .utf8, to: .shiftJIS, sliceSize: 4096)
        XCTAssertTrue(lossy)
    }

    /// 空入力は空出力・非 lossy。
    func testEmptyInput() throws {
        let (out, lossy) = try transcode(Data(), from: .utf8, to: .shiftJIS, sliceSize: 8)
        XCTAssertTrue(out.isEmpty)
        XCTAssertFalse(lossy)
    }
}
