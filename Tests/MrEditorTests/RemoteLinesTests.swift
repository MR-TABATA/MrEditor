import XCTest
@testable import MrEditorCore

/// 遠隔から来たバイト列を行に直すところ。
///
/// **一番危ないのは、半端な行を 1 行として見せること。** `tail -c` はバイトで切るので
/// 最初の行は途中から始まっていることがあり、それをそのまま並べると
/// 「そこだけ本文が欠けたまま、それらしく読める」状態になる。
final class RemoteLinesTests: XCTestCase {

    private var dropped = false

    // MARK: - 末尾を割る

    /// ファイル全体を渡したときは、先頭の行は欠けていない。
    func testWholeFileKeepsEveryLine() {
        let data = Data("a\nb\nc\n".utf8)
        let lines = RemoteLines.fromTail(data, endsAtByte: data.count, totalLines: 3, droppedLeadingPartial: &dropped)
        XCTAssertFalse(dropped)
        XCTAssertEqual(lines.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(lines.map(\.number), [1, 2, 3])
    }

    /// **途中から切り出したら、最初の行は捨てる。**
    func testPartialLeadingLineIsDropped() {
        // 実ファイルは "aaa\nbbb\nccc\n"。末尾 8 バイトだけ取ると "a\nbbb\nccc\n"
        let data = Data("a\nbbb\nccc\n".utf8)
        let lines = RemoteLines.fromTail(data, endsAtByte: 12, totalLines: 3, droppedLeadingPartial: &dropped)
        XCTAssertTrue(dropped, "半端な先頭行を捨てていない")
        XCTAssertEqual(lines.map(\.text), ["bbb", "ccc"])
        XCTAssertEqual(lines.map(\.number), [2, 3])
    }

    /// 総行数が分からなければ番号は nil。**0 とも 1 とも書かない。**
    func testUnknownTotalLeavesNumbersNil() {
        let data = Data("x\ny\n".utf8)
        let lines = RemoteLines.fromTail(data, endsAtByte: data.count, totalLines: nil, droppedLeadingPartial: &dropped)
        XCTAssertEqual(lines.map(\.text), ["x", "y"])
        XCTAssertEqual(lines.map(\.number), [nil, nil])
    }

    /// `wc -l` は改行の数。**末尾に改行が無ければ、最終行はそのぶん 1 本多い。**
    func testFileWithoutTrailingNewlineNumbersTheLastLine() {
        let data = Data("a\nb\nc".utf8)          // 改行 2 つ、行は 3 本
        let lines = RemoteLines.fromTail(data, endsAtByte: data.count, totalLines: 2, droppedLeadingPartial: &dropped)
        XCTAssertEqual(lines.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(lines.map(\.number), [1, 2, 3])
    }

    func testEmptyDataYieldsNoLines() {
        XCTAssertTrue(RemoteLines.fromTail(Data(), endsAtByte: 0, totalLines: 0, droppedLeadingPartial: &dropped).isEmpty)
    }

    /// 末尾の改行で「空の最終行」を作らない。
    func testTrailingNewlineDoesNotCreateAnEmptyLine() {
        let data = Data("only\n".utf8)
        let lines = RemoteLines.fromTail(data, endsAtByte: data.count, totalLines: 1, droppedLeadingPartial: &dropped)
        XCTAssertEqual(lines.map(\.text), ["only"])
    }

    /// 末尾 1 行だけを取った場合。捨てる先が無いので捨てない。
    func testSingleLineWindowIsKept() {
        let data = Data("tail-only\n".utf8)
        let lines = RemoteLines.fromTail(data, endsAtByte: 9999, totalLines: 100, droppedLeadingPartial: &dropped)
        XCTAssertFalse(dropped)
        XCTAssertEqual(lines.map(\.text), ["tail-only"])
        XCTAssertEqual(lines.map(\.number), [100])
    }

    // MARK: - grep の結果

    func testMatchesKeepTheirNumbersAndMatchFlag() {
        let matches = [
            RemoteFile.Match(line: 9, isMatch: false, text: "before"),
            RemoteFile.Match(line: 10, isMatch: true, text: "hit"),
        ]
        let lines = RemoteLines.fromMatches(matches)
        XCTAssertEqual(lines.map(\.number), [9, 10])
        XCTAssertEqual(lines.map(\.isMatch), [false, true])
    }

    // MARK: - 手元へ持っていく

    /// **クリップボードが遠隔と手元の継ぎ目。** 既定で行番号を付けないのは、
    /// 付けると本文でなくなり、diff にかけたときに全行が差分になるため。
    func testPlainTextIsBodyOnlyByDefault() {
        let lines = [
            RemoteLine(number: 10, isMatch: true, text: "ERROR boom"),
            RemoteLine(number: 11, isMatch: false, text: "  at foo()"),
        ]
        XCTAssertEqual(RemoteLines.plainText(lines), "ERROR boom\n  at foo()")
        XCTAssertEqual(RemoteLines.plainText(lines, withNumbers: true), "10:ERROR boom\n11:  at foo()")
    }

    func testPlainTextSurvivesUnknownNumbers() {
        let lines = [RemoteLine(number: nil, isMatch: false, text: "x")]
        XCTAssertEqual(RemoteLines.plainText(lines, withNumbers: true), "x")
    }
}
