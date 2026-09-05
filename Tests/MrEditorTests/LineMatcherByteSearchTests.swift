import XCTest
@testable import MrEditorCore

/// 非 UTF-8 をバイトのまま探す経路の検証（2026-09-05 に追加）。
///
/// **ここが落ちると、検索結果が静かに間違う。** 利用者からは確かめる手段がないので、
/// 誤爆する形を先に並べて固定しておく。とくに Shift-JIS は 2 バイト目が ASCII と
/// 重なるので、素朴なバイト比較は必ず誤爆する。
final class LineMatcherByteSearchTests: XCTestCase {

    private func sjis(_ s: String) -> [UInt8] { [UInt8](s.data(using: .shiftJIS)!) }
    private func euc(_ s: String) -> [UInt8] { [UInt8](s.data(using: .japaneseEUC)!) }

    private func matches(_ line: [UInt8], _ terms: [String],
                         encoding: DetectedEncoding, caseSensitive: Bool = false) -> Bool {
        let m = LineMatcher(mode: .terms(terms), caseSensitive: caseSensitive, encoding: encoding)
        return line.withUnsafeBufferPointer { m.matches($0) }
    }

    /// 「デコードして文字列で照合」した場合の答え。バイト経路はこれと一致しなければならない。
    private func expected(_ line: [UInt8], _ terms: [String],
                          encoding: DetectedEncoding, caseSensitive: Bool = false) -> Bool {
        let s = String(data: Data(line), encoding: encoding.stringEncoding)!
        let options: NSString.CompareOptions = caseSensitive ? [] : .caseInsensitive
        return terms.allSatisfy { s.range(of: $0, options: options) != nil }
    }

    // MARK: - 誤爆（これが本題）

    /// Shift-JIS の「ア」は `83 41`。語 "A"（`41`）は **2 バイト目に当たってはいけない**。
    func testAsciiTermDoesNotHitTrailByte() {
        let line = sjis("アイウ")
        XCTAssertEqual(sjis("ア"), [0x83, 0x41], "前提: ア の 2 バイト目が 'A' と同じ")
        XCTAssertFalse(matches(line, ["A"], encoding: .shiftJIS))
        XCTAssertEqual(matches(line, ["A"], encoding: .shiftJIS),
                       expected(line, ["A"], encoding: .shiftJIS))
    }

    /// 同じ行に本物の "A" があれば当たる（弾きすぎていないこと）。
    func testAsciiTermStillHitsRealAscii() {
        let line = sjis("アA イ")
        XCTAssertTrue(matches(line, ["A"], encoding: .shiftJIS))
        XCTAssertTrue(matches(line, ["a"], encoding: .shiftJIS), "大小無視")
        XCTAssertFalse(matches(line, ["a"], encoding: .shiftJIS, caseSensitive: true))
    }

    /// 2 バイト目どうしが繋がって偽の語を作る形。「ア」+「ア」= `83 41 83 41`。
    /// 語 "A" は 1 バイト目（`83`）の直後にも見えるが、どちらも文字の途中。
    func testRepeatedTrailBytesNeverMatch() {
        let line = sjis("アアアア")
        XCTAssertFalse(matches(line, ["A"], encoding: .shiftJIS))
    }

    /// 半角カナ（`A0..DF`）は 1 バイト文字。ここを 2 バイトと数えると切れ目がずれて、
    /// 後ろの当たりを取りこぼす。
    func testHalfWidthKatakanaIsOneByte() {
        let line = sjis("ｱｲｳ=A")
        XCTAssertTrue(matches(line, ["A"], encoding: .shiftJIS))
        XCTAssertEqual(matches(line, ["A"], encoding: .shiftJIS),
                       expected(line, ["A"], encoding: .shiftJIS))
    }

    /// EUC-JP の補助漢字は 3 バイト（`8F` 始まり）。ここを 2 バイトと数えるとずれる。
    func testEucSupplementaryKanjiIsThreeBytes() {
        let line = euc("漢字テスト=A")
        XCTAssertTrue(matches(line, ["A"], encoding: .eucJP))
        XCTAssertTrue(matches(line, ["漢字"], encoding: .eucJP))
        XCTAssertFalse(matches(line, ["Z"], encoding: .eucJP))
    }

    // MARK: - 素直に当たる形

    func testJapaneseTermMatches() {
        let line = sjis("1,\"株式会社ミライト・ワン\",\"東京都\"")
        XCTAssertTrue(matches(line, ["株式会社ミライト・ワン"], encoding: .shiftJIS))
        XCTAssertTrue(matches(line, ["東京都"], encoding: .shiftJIS))
        XCTAssertFalse(matches(line, ["大阪府"], encoding: .shiftJIS))
    }

    /// 複数語は AND。
    func testTermsAreAnded() {
        let line = sjis("\"株式会社ミライト・ワン\",\"東京都\"")
        XCTAssertTrue(matches(line, ["ミライト", "東京"], encoding: .shiftJIS))
        XCTAssertFalse(matches(line, ["ミライト", "大阪"], encoding: .shiftJIS))
    }

    /// 全角 Ａ は大小を持つので、大小無視のときはバイト経路に乗せない
    /// （`.caseInsensitive` は Ａ と ａ を同一視するが、バイト比較では出せない）。
    func testFullWidthLatinFallsBackToDecoding() {
        XCTAssertTrue(LineMatcher.hasNonASCIICase("Ａ"))
        XCTAssertFalse(LineMatcher.hasNonASCIICase("株式会社"))
        XCTAssertFalse(LineMatcher.hasNonASCIICase("ABC"))

        let line = sjis("値=ａ")
        XCTAssertTrue(matches(line, ["Ａ"], encoding: .shiftJIS), "全角の大小も無視される")
        XCTAssertEqual(matches(line, ["Ａ"], encoding: .shiftJIS),
                       expected(line, ["Ａ"], encoding: .shiftJIS))
    }

    /// 対象のエンコーディングで表せない語（Shift-JIS に無い絵文字）はデコード経路へ。
    /// 落ちずに「当たらない」を返すこと。
    func testUnencodableTermFallsBack() {
        XCTAssertNil(LineMatcher.encode(["🎉"], to: .shiftJIS))
        let line = sjis("ふつうの行")
        XCTAssertFalse(matches(line, ["🎉"], encoding: .shiftJIS))
    }

    /// 空の語しかないときは「探していない」。走査そのものを省く側が見る。
    func testEmptyTerms() {
        XCTAssertTrue(LineMatcher(mode: .terms([]), caseSensitive: false, encoding: .shiftJIS).isEmpty)
        XCTAssertFalse(LineMatcher(mode: .terms(["あ"]), caseSensitive: false, encoding: .shiftJIS).isEmpty)
        // 変換できない語でも「探している」ままであること（バイト列が空でも省かない）。
        XCTAssertFalse(LineMatcher(mode: .terms(["🎉"]), caseSensitive: false, encoding: .shiftJIS).isEmpty)
    }

    // MARK: - デコード経路と総当たりで突き合わせる

    /// **同じ式で違う結果が出るのが最悪**なので、生成した行と語の全組み合わせで
    /// 「デコードして照合」と一致することを確かめる。
    func testAgreesWithDecodingOnManyCombinations() {
        let pieces = ["ア", "A", "a", "亜", "ｱ", "1", ",", "\"", "株式会社", "ミライト", "・", "－"]
        let terms = ["A", "a", "ア", "亜", "株式会社", "ミライト", "1", "・", "Aア", "ア亜"]
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            var text = ""
            for _ in 0..<Int.random(in: 1...10, using: &rng) {
                text += pieces.randomElement(using: &rng)!
            }
            guard let data = text.data(using: .shiftJIS) else { continue }
            let line = [UInt8](data)
            for term in terms {
                for caseSensitive in [true, false] {
                    let got = matches(line, [term], encoding: .shiftJIS, caseSensitive: caseSensitive)
                    let want = expected(line, [term], encoding: .shiftJIS, caseSensitive: caseSensitive)
                    XCTAssertEqual(got, want,
                                   "行「\(text)」 語「\(term)」 caseSensitive=\(caseSensitive)")
                }
            }
        }
    }

    /// EUC-JP でも同じ突き合わせ。
    func testAgreesWithDecodingOnEuc() {
        let pieces = ["漢", "A", "a", "ア", "1", ",", "テスト", "・"]
        let terms = ["A", "a", "漢", "ア", "テスト", "1"]
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var text = ""
            for _ in 0..<Int.random(in: 1...10, using: &rng) {
                text += pieces.randomElement(using: &rng)!
            }
            guard let data = text.data(using: .japaneseEUC) else { continue }
            let line = [UInt8](data)
            for term in terms {
                let got = matches(line, [term], encoding: .eucJP)
                let want = expected(line, [term], encoding: .eucJP)
                XCTAssertEqual(got, want, "行「\(text)」 語「\(term)」")
            }
        }
    }
}
