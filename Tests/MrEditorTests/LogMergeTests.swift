import XCTest
@testable import MrEditor

/// 時刻の読み取り（`TimestampDetector`）と、複数ログの時系列統合（`LogMerger`）。
///
/// 時刻の期待値はすべてエポック秒の実数で書く。`DateFormatter` で期待値を作ると
/// テスト自身が実装と同じ勘違いをしても気づけないため。
/// 2026-07-30T12:34:56Z = 1785414896（`date -u -r 1785414896` で確認）。
final class LogMergeTests: XCTestCase {

    private let base = 1_785_414_896.0     // 2026-07-30 12:34:56 UTC
    private let jst = 9 * 3600

    private func epoch(_ d: Date?) -> Double? { d?.timeIntervalSince1970 }

    // MARK: - ISO8601

    func testISO8601WithZuluAndOffset() {
        let d = TimestampDetector(format: .iso8601, timeZoneOffset: 0)
        XCTAssertEqual(epoch(d.parse("2026-07-30T12:34:56Z hello")), base)
        // +09:00 の 21:34:56 は UTC の 12:34:56 と同じ瞬間
        XCTAssertEqual(epoch(d.parse("2026-07-30T21:34:56+09:00 hello")), base)
        XCTAssertEqual(epoch(d.parse("2026-07-30T07:34:56-0500 hello")), base)
    }

    func testISO8601SpaceSeparatorAndCommaMillis() {
        let d = TimestampDetector(format: .iso8601, timeZoneOffset: 0)
        // Java 系ログの "," 区切りミリ秒
        XCTAssertEqual(epoch(d.parse("2026-07-30 12:34:56,250 ERROR boom"))!, base + 0.25, accuracy: 1e-9)
        XCTAssertEqual(epoch(d.parse("2026-07-30T12:34:56.500Z"))!, base + 0.5, accuracy: 1e-9)
    }

    /// オフセットが書かれていない行は、行ごとに勝手に決めず設定側の既定を使う。
    func testISO8601WithoutOffsetUsesConfiguredZone() {
        let d = TimestampDetector(format: .iso8601, timeZoneOffset: jst)
        XCTAssertEqual(epoch(d.parse("2026-07-30 21:34:56 hello")), base)
    }

    func testISO8601RejectsNonTimestampLines() {
        let d = TimestampDetector(format: .iso8601, timeZoneOffset: 0)
        XCTAssertNil(d.parse("    at com.example.Foo.bar(Foo.java:42)"))
        XCTAssertNil(d.parse(""))
        XCTAssertNil(d.parse("2026-13-99T99:99:99Z"))   // 範囲外は撥ねる
    }

    // MARK: - syslog（年が無い）

    func testSyslogUsesAssumedYearAndPadsSingleDigitDay() {
        let d = TimestampDetector(format: .syslog, timeZoneOffset: 0, assumedYear: 2026)
        XCTAssertEqual(epoch(d.parse("Jul 30 12:34:56 web-1 sshd[1]: ok")), base)
        // 1桁の日は空白詰め（Jul  3）
        let three = d.parse("Jul  3 00:00:00 web-1 sshd[1]: ok")
        XCTAssertEqual(epoch(three), base - 27 * 86_400 - 45_296)
    }

    /// 12月31日 → 1月1日。年を固定したままだと約11か月巻き戻り、並べ替えでログが裏返る。
    func testSyslogYearRollover() {
        let d = TimestampDetector(format: .syslog, timeZoneOffset: 0, assumedYear: 2026)
        let times = d.parseAll([
            "Dec 31 23:59:58 web-1 last of the year",
            "Dec 31 23:59:59 web-1 still 2026",
            "Jan  1 00:00:00 web-1 happy new year",
            "Jan  1 00:00:01 web-1 still 2027",
        ])
        let secs = times.map { $0!.timeIntervalSince1970 }
        XCTAssertEqual(secs, secs.sorted(), "年またぎで時刻が巻き戻ってはいけない")
        XCTAssertEqual(secs[2] - secs[1], 1.0, accuracy: 1e-9)
    }

    // MARK: - Apache

    func testApacheCommonLog() {
        let d = TimestampDetector(format: .apache, timeZoneOffset: 0)
        let line = #"127.0.0.1 - alice [30/Jul/2026:21:34:56 +0900] "GET / HTTP/1.1" 200 42"#
        XCTAssertEqual(epoch(d.parse(line)), base)
    }

    // MARK: - エポック

    func testEpochSecondsAndMillis() {
        let s = TimestampDetector(format: .epochSeconds, timeZoneOffset: jst)
        XCTAssertEqual(epoch(s.parse("1754000000 started")), 1_754_000_000)
        XCTAssertEqual(epoch(s.parse("1754000000.250 started"))!, 1_754_000_000.25, accuracy: 1e-9)

        let m = TimestampDetector(format: .epochMillis, timeZoneOffset: jst)
        XCTAssertEqual(epoch(m.parse("1754000000123 started"))!, 1_754_000_000.123, accuracy: 1e-6)
    }

    /// 行頭に ID を持つログをエポックとして誤読しないこと（桁数と直後の文字で弾く）。
    func testEpochRejectsIdLikePrefix() {
        let s = TimestampDetector(format: .epochSeconds, timeZoneOffset: 0)
        XCTAssertNil(s.parse("12345 short id"))
        XCTAssertNil(s.parse("1754000000123 これは13桁なので秒ではない"))
        XCTAssertNil(s.parse("1754000000abc trailing letters"))
    }

    // MARK: - 形式の自動判定

    func testDetectPicksTheRightFormat() {
        XCTAssertEqual(TimestampDetector.detect(sampleLines: [
            "2026-07-30T12:34:56Z a", "2026-07-30T12:34:57Z b",
        ])?.format, .iso8601)

        XCTAssertEqual(TimestampDetector.detect(sampleLines: [
            "Jul 30 12:34:56 web-1 a", "Jul 30 12:34:57 web-1 b",
        ])?.format, .syslog)

        XCTAssertEqual(TimestampDetector.detect(sampleLines: [
            #"127.0.0.1 - - [30/Jul/2026:12:34:56 +0900] "GET / HTTP/1.1" 200 1"#,
        ])?.format, .apache)

        XCTAssertEqual(TimestampDetector.detect(sampleLines: [
            "1754000000 a", "1754000001 b", "1754000002 c",
        ])?.format, .epochSeconds)
    }

    /// 国税庁の法人番号 CSV は先頭が13桁の数字＝そのままではエポックミリ秒に見える。
    /// 実データで踏む誤判定なので、単調でないことを根拠に撥ねる。
    func testDetectRejectsIdColumnThatLooksLikeEpochMillis() {
        let corporateNumbers = [
            "1000012010001,01,2018-04-02,内閣官房",
            "5000012050002,01,2018-04-02,法務省",
            "2000012060001,01,2018-04-02,財務省",
            "9000012070001,01,2018-04-02,文部科学省",
            "4000012090001,01,2018-04-02,厚生労働省",
        ]
        XCTAssertNil(TimestampDetector.detect(sampleLines: corporateNumbers),
                     "ID の列を時刻と誤読してはいけない")
    }

    /// 逆に、本物のエポックミリ秒のログはちゃんと通る。
    func testDetectAcceptsMonotonicEpochMillis() {
        let lines = (0..<5).map { "175400000\($0)123 event" }
        XCTAssertEqual(TimestampDetector.detect(sampleLines: lines)?.format, .epochMillis)
    }

    func testMonotonicRatio() {
        let t = { (s: Double) in Date(timeIntervalSince1970: s) }
        XCTAssertEqual(TimestampDetector.monotonicRatio([t(1), t(2), t(3)]), 1.0)
        XCTAssertEqual(TimestampDetector.monotonicRatio([t(3), t(2), t(1)]), 0.0)
        XCTAssertEqual(TimestampDetector.monotonicRatio([t(1)]), 1.0, "1件では判断しない")
    }

    /// 時刻を持たないファイルは nil（＝時刻なしとして扱い、勝手に何かに当てはめない）。
    func testDetectReturnsNilForTimestamplessInput() {
        XCTAssertNil(TimestampDetector.detect(sampleLines: [
            "hello world", "just some text", "no timestamps here",
        ]))
        XCTAssertNil(TimestampDetector.detect(sampleLines: []))
    }

    /// 時刻を持たない行が大半でも、少数でも当たれば形式は決まる（スタックトレース主体のログ）。
    func testDetectSurvivesMostlyTimestamplessInput() {
        var lines = ["2026-07-30T12:34:56Z ERROR boom"]
        lines += (0..<30).map { "    at com.example.Foo.bar(Foo.java:\($0))" }
        XCTAssertEqual(TimestampDetector.detect(sampleLines: lines)?.format, .iso8601)
    }

    // MARK: - 実ログからの写し
    //
    // 以下の行は実際に macOS 上のログから採ったもの。作った入力だけでテストすると、
    // 自分が想像した形式しか通らないことに気づけない（実際 2桁オフセットはここで出た）。

    /// `/var/log/install.log`。オフセットが `-07` と**2桁**。分が無い。
    func testRealInstallLogHasTwoDigitOffset() {
        let d = TimestampDetector(format: .iso8601, timeZoneOffset: jst)   // 既定は JST にしておく
        let line = "2025-07-18 08:15:05-07 localhost Installer Progress[56]: Progress UI App Starting"
        // -07 を読めていれば 15:15:05Z。読み落として JST 既定に落ちると 23:15:05Z になる。
        XCTAssertEqual(epoch(d.parse(line)), 1_752_851_705, "2桁オフセットを取りこぼすと数時間ずれる")
        XCTAssertEqual(TimestampDetector.detect(sampleLines: [line])?.format, .iso8601)
    }

    /// `/var/log/system.log`。素の syslog。
    func testRealSystemLog() {
        let lines = [
            "Aug  4 00:04:03 Mac-mini-m1-2 syslogd[363]: ASL Sender Statistics",
            "Aug  4 00:21:06 Mac-mini-m1-2 syslogd[363]: ASL Sender Statistics",
        ]
        XCTAssertEqual(TimestampDetector.detect(sampleLines: lines)?.format, .syslog)
        let d = TimestampDetector(format: .syslog, timeZoneOffset: 0, assumedYear: 2026)
        XCTAssertNotNil(d.parse(lines[0]))
    }

    /// `/var/log/wifi.log` は syslog 行と `Tue Aug  4 …` 行が混ざっている。
    /// 曜日つきの行は読めなくてよいが、**ファイル全体の判定は syslog に落ち着く**こと。
    func testRealWifiLogWithMixedWeekdayPrefix() {
        let lines = [
            "Aug  4 00:39:29 Mac-mini-m1-2 newsyslog[17283]: logfile turned over",
            "Tue Aug  4 00:39:29.475 [airport]/420 @[276161.593952] dq:'com.apple.main-thread'",
        ]
        XCTAssertEqual(TimestampDetector.detect(sampleLines: lines)?.format, .syslog)
        let d = TimestampDetector(format: .syslog, timeZoneOffset: 0, assumedYear: 2026)
        XCTAssertNotNil(d.parse(lines[0]))
        XCTAssertNil(d.parse(lines[1]), "曜日つきは読めないが、継続行として扱えばよい")
    }

    // MARK: - 暦

    func testCivilRoundTripAcrossLeapRules() {
        for (y, m, d) in [(1970, 1, 1), (2000, 2, 29), (1900, 3, 1), (2024, 2, 29), (2026, 12, 31)] {
            let days = TimestampDetector.daysFromCivil(y, m, d)
            let back = TimestampDetector.civilFromDays(days)
            XCTAssertEqual(back.year, y)
            XCTAssertEqual(back.month, m)
            XCTAssertEqual(back.day, d)
        }
        XCTAssertEqual(TimestampDetector.daysFromCivil(1970, 1, 1), 0)
    }

    // MARK: - 実効時刻（継続行の引き継ぎ）

    func testEffectiveTimesCarriesForwardAndBackfillsHead() {
        let t0 = Date(timeIntervalSince1970: 100)
        let t1 = Date(timeIntervalSince1970: 200)
        let got = LogMerger.effectiveTimes([nil, t0, nil, nil, t1, nil])
        XCTAssertEqual(got.map { $0?.timeIntervalSince1970 },
                       [100, 100, 100, 100, 200, 200],
                       "継続行は直前の時刻を引き継ぎ、冒頭の見出し行は最初の時刻を借りる")
    }

    func testEffectiveTimesWithNoTimestampsAtAll() {
        XCTAssertEqual(LogMerger.effectiveTimes([nil, nil, nil]).compactMap { $0 }.count, 0)
    }

    func testEffectiveTimesAppliesClockOffset() {
        let t = Date(timeIntervalSince1970: 100)
        let got = LogMerger.effectiveTimes([t], clockOffset: -1.5)
        XCTAssertEqual(got[0]?.timeIntervalSince1970, 98.5)
    }

    // MARK: - 統合

    private func at(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }

    func testMergeInterleavesByTime() {
        let a = LogMerger.Source(label: "web-1", times: [at(10), at(30)])
        let b = LogMerger.Source(label: "web-2", times: [at(20), at(40)])
        let got = LogMerger.merge([a, b])
        XCTAssertEqual(got.map { [$0.source, $0.line] }, [[0, 0], [1, 0], [0, 1], [1, 1]])
        XCTAssertEqual(got.map { $0.time?.timeIntervalSince1970 }, [10, 20, 30, 40])
    }

    /// これが `sort -m` と決定的に違うところ。継続行が親から引き剥がされない。
    func testMergeKeepsContinuationLinesWithTheirParent() {
        let a = LogMerger.Source(label: "app", times: [at(10), nil, nil, at(30)])   // 10 の直後にスタックトレース2行
        let b = LogMerger.Source(label: "db", times: [at(20)])
        let got = LogMerger.merge([a, b])

        XCTAssertEqual(got.map { [$0.source, $0.line] },
                       [[0, 0], [0, 1], [0, 2], [1, 0], [0, 3]],
                       "時刻を持たない継続行は親の直後に残ること")
        XCTAssertEqual(got.map { $0.hasOwnTimestamp }, [true, false, false, true, true])
    }

    /// 同時刻が並んでも順序が揺れない（開くたびに並びが変わらない）。
    func testMergeIsStableOnEqualTimestamps() {
        let a = LogMerger.Source(label: "a", times: [at(10), at(10)])
        let b = LogMerger.Source(label: "b", times: [at(10), at(10)])
        let got = LogMerger.merge([a, b])
        XCTAssertEqual(got.map { [$0.source, $0.line] }, [[0, 0], [0, 1], [1, 0], [1, 1]])
        XCTAssertEqual(LogMerger.merge([a, b]), got, "同じ入力なら常に同じ結果")
    }

    /// NTP がずれた1台。補正しないと因果が逆に見える。
    func testMergeAppliesClockOffset() {
        let slow = LogMerger.Source(label: "slow", times: [at(25)], clockOffset: -10)  // 実際は 15
        let other = LogMerger.Source(label: "other", times: [at(20)])
        XCTAssertEqual(LogMerger.merge([slow, other]).map { $0.source }, [0, 1])

        let uncorrected = LogMerger.Source(label: "slow", times: [at(25)])
        XCTAssertEqual(LogMerger.merge([uncorrected, other]).map { $0.source }, [1, 0])
    }

    /// 時刻を1つも持たないソースは、時刻を持つ行を全部出したあとに続く。
    func testMergePlacesTimestamplessSourceLast() {
        let timed = LogMerger.Source(label: "timed", times: [at(10), at(20)])
        let plain = LogMerger.Source(label: "plain", times: [nil, nil])
        let got = LogMerger.merge([plain, timed])
        XCTAssertEqual(got.map { [$0.source, $0.line] }, [[1, 0], [1, 1], [0, 0], [0, 1]])
    }

    /// 何があっても行を落とさない・増やさない。
    func testMergePreservesEveryLine() {
        let sources = [
            LogMerger.Source(label: "a", times: [at(5), nil, at(50)]),
            LogMerger.Source(label: "b", times: []),
            LogMerger.Source(label: "c", times: [nil, at(1), nil, nil]),
        ]
        let got = LogMerger.merge(sources)
        XCTAssertEqual(got.count, 7)
        for (i, s) in sources.enumerated() {
            let lines = got.filter { $0.source == i }.map { $0.line }
            XCTAssertEqual(lines, Array(0..<s.times.count), "ソース内の行順は必ず保たれる")
        }
    }

    func testMergeOfNothing() {
        XCTAssertTrue(LogMerger.merge([]).isEmpty)
        XCTAssertTrue(LogMerger.merge([LogMerger.Source(label: "empty", times: [])]).isEmpty)
    }

    // MARK: - 検出から統合まで通しで

    func testEndToEndThreeHostsWithSkewAndStackTrace() {
        let web1 = [
            "2026-07-30T12:34:56Z GET /health 200",
            "2026-07-30T12:34:58Z GET /buy 500",
        ]
        let app = [
            "2026-07-30T12:34:57Z ERROR NullPointerException",
            "    at com.example.Checkout.pay(Checkout.java:88)",
            "    at com.example.Web.handle(Web.java:12)",
        ]
        let db = ["2026-07-30T12:34:59Z slow query 3200ms"]

        let d = TimestampDetector.detect(sampleLines: web1 + app + db, timeZoneOffset: 0)
        XCTAssertEqual(d?.format, .iso8601)
        guard let d else { return XCTFail("形式を判定できなかった") }

        let merged = LogMerger.merge([
            LogMerger.Source(label: "web-1", times: d.parseAll(web1)),
            LogMerger.Source(label: "app", times: d.parseAll(app)),
            LogMerger.Source(label: "db", times: d.parseAll(db), clockOffset: -2),  // 2秒進んだ時計
        ])

        // db は記録上 12:34:59 だが 2 秒進んでいるので実際は 12:34:57 → app の直後
        XCTAssertEqual(merged.map { [$0.source, $0.line] },
                       [[0, 0], [1, 0], [1, 1], [1, 2], [2, 0], [0, 1]])
        XCTAssertEqual(merged.count, web1.count + app.count + db.count)
    }
}
