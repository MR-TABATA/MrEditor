import Foundation

/// 複数のログファイルを読み、時刻で1本に束ねて1つのテキストにする。
///
/// `TimestampDetector` / `LogMerger`（どちらも純関数）に、ファイル読み込みと
/// 見せ方だけを足す層。ここが唯一 I/O を持つ。
///
/// **結果は一時ファイルに書き出し、通常の「開く」経路に流す。** 専用のビューアを
/// 作らないことで、検索・フィルタ・構造化表示・別名保存・行ジャンプが全部そのまま
/// 効く。束ねた結果が大きければ既存の大ファイル経路（`PieceTableViewer`）に自動で
/// 乗るので、表示側のメモリ設計にも手を入れずに済む。
///
/// **形式はファイルごとに判定する。** nginx（Apache 形式）とアプリログ（ISO）を
/// 一緒に束ねるのが現実の使い方で、全体で1つの形式に決めつけると片方が丸ごと
/// 継続行になって時系列が崩れる。
struct MergedLogBuilder {

    /// 束ねた1本ぶんの素性（見出しに出す）。
    struct SourceInfo {
        let label: String
        let url: URL
        let format: TimestampFormat?
        let lineCount: Int
        let timestampedCount: Int
    }

    struct Result {
        /// 書き出した一時ファイル。
        let url: URL
        let sources: [SourceInfo]
        let totalLines: Int
        /// 読めなかった・時刻が無かったなど、利用者に伝えるべきこと。
        let warnings: [String]
    }

    enum Failure: LocalizedError {
        case needsTwoFiles
        case tooLarge(bytes: Int, limit: Int)
        case unreadable(URL)
        case writeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .needsTwoFiles:
                return L("merge.error.needsTwoFiles")
            case let .tooLarge(bytes, limit):
                return String(format: L("merge.error.tooLarge"),
                              ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file),
                              ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))
            case let .unreadable(url):
                return String(format: L("merge.error.unreadable"), url.lastPathComponent)
            case let .writeFailed(e):
                return e.localizedDescription
            }
        }
    }

    /// 入力の合計サイズの上限。
    ///
    /// 束ねるには**全行の時刻を先に知る必要がある**ので、10GB を素通しするわけには
    /// いかない（並べ替えは全件を見るまで1行目が確定しない）。ここは正直に上限を
    /// 設けて断る。上限を超えるものを黙って途中まで束ねるのが一番悪い。
    static let inputSizeLimit = 512 * 1024 * 1024

    /// 表示に使う UTC オフセット（秒）。既定はローカル。
    let displayOffset: Int
    /// 行に書かれていないときに仮定する UTC オフセット（秒）。
    let assumedOffset: Int
    /// 年を持たない形式（syslog）で仮定する年。
    let assumedYear: Int

    init(displayOffset: Int = TimeZone.current.secondsFromGMT(),
         assumedOffset: Int = TimeZone.current.secondsFromGMT(),
         assumedYear: Int = Calendar(identifier: .gregorian).component(.year, from: Date())) {
        self.displayOffset = displayOffset
        self.assumedOffset = assumedOffset
        self.assumedYear = assumedYear
    }

    // MARK: - 本体

    func build(urls: [URL], into directory: URL? = nil) throws -> Result {
        guard urls.count >= 2 else { throw Failure.needsTwoFiles }

        let total = urls.reduce(0) { sum, u in
            sum + ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0 ?? 0)
        }
        guard total <= Self.inputSizeLimit else {
            throw Failure.tooLarge(bytes: total, limit: Self.inputSizeLimit)
        }

        var warnings: [String] = []
        var infos: [SourceInfo] = []
        var texts: [[String]] = []
        var sources: [LogMerger.Source] = []

        for (i, url) in urls.enumerated() {
            guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(url) }
            let encoding = EncodingDetector.detect(data)
            guard let text = String(data: data, encoding: encoding.stringEncoding) else {
                throw Failure.unreadable(url)
            }
            // 改行は CRLF/CR も受ける。表示は LF に揃える。
            var lines = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            // 末尾の改行で生まれる幻の空行を1つだけ落とす。テキストファイルは改行で
            // 終わるのが普通なので、これを残すと**ファイルの数だけ空行が混ざる**。
            // 継続行として直前の時刻を引き継ぐぶん、ラベルだけの行として見えてしまう。
            if lines.last == "" { lines.removeLast() }

            let label = Self.label(for: url, index: i, among: urls)
            let sample = Array(lines.prefix(500))
            let detector = TimestampDetector.detect(sampleLines: sample,
                                                    timeZoneOffset: assumedOffset,
                                                    assumedYear: assumedYear)
            let times = detector?.parseAll(lines) ?? [Date?](repeating: nil, count: lines.count)
            let hits = times.reduce(0) { $0 + ($1 == nil ? 0 : 1) }

            if detector == nil {
                warnings.append(String(format: L("merge.warn.noTimestamp"), url.lastPathComponent))
            }
            infos.append(SourceInfo(label: label, url: url, format: detector?.format,
                                    lineCount: lines.count, timestampedCount: hits))
            texts.append(lines)
            sources.append(LogMerger.Source(label: label, times: times))
        }

        let merged = LogMerger.merge(sources)
        let labelWidth = infos.map { $0.label.count }.max() ?? 0

        var out = header(infos: infos, totalLines: merged.count, warnings: warnings)
        out.reserveCapacity(merged.count * 96)
        var lastStamp = ""
        for e in merged {
            let stamp = e.hasOwnTimestamp ? Self.format(e.time, offset: displayOffset) : ""
            // 継続行は時刻欄を空にする。親の時刻を引き継いでいるだけなので、
            // そこに数字を出すと「その行自身が持っている時刻」に見えて嘘になる。
            out += stamp.isEmpty ? String(repeating: " ", count: lastStamp.count) : stamp
            if !stamp.isEmpty { lastStamp = stamp }
            out += " │ "
            out += infos[e.source].label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            out += " │ "
            out += texts[e.source][e.line]
            out += "\n"
        }

        let dir = directory ?? FileManager.default.temporaryDirectory
        let name = "merged-\(urls.count)files-\(Self.stamp()).log"
        let dest = dir.appendingPathComponent(name)
        do {
            try out.write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            throw Failure.writeFailed(error)
        }
        return Result(url: dest, sources: infos, totalLines: merged.count, warnings: warnings)
    }

    // MARK: - 見出し

    private func header(infos: [SourceInfo], totalLines: Int, warnings: [String]) -> String {
        var s = "# " + String(format: L("merge.header.title"), infos.count, totalLines) + "\n"
        for i in infos {
            let fmt = i.format?.rawValue ?? L("merge.header.noFormat")
            s += "#   \(i.label)  \(i.url.lastPathComponent)  (\(fmt), "
            s += String(format: L("merge.header.lines"), i.lineCount, i.timestampedCount) + ")\n"
        }
        for w in warnings { s += "# ⚠️ \(w)\n" }
        s += "#\n"
        return s
    }

    // MARK: - 小道具

    /// 表示名。同名ファイルが混ざるとき（`web-1/app.log` と `web-2/app.log`）は
    /// 親ディレクトリまで足す。ホスト別に集めたログでこれが起きないと区別できない。
    static func label(for url: URL, index: Int, among urls: [URL]) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let duplicated = urls.filter { $0.deletingPathExtension().lastPathComponent == base }.count > 1
        guard duplicated else { return base }
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? "\(base)-\(index + 1)" : "\(parent)/\(base)"
    }

    /// `2026-07-30 12:34:56.789`。`DateFormatter` は使わない（行数ぶん呼ばれる）。
    static func format(_ date: Date?, offset: Int) -> String {
        guard let date else { return "" }
        let total = date.timeIntervalSince1970 + Double(offset)
        let whole = Int(floor(total))
        let millis = Int(((total - floor(total)) * 1000).rounded())
        let days = Int(floor(Double(whole) / 86_400))
        let rem = whole - days * 86_400
        let c = TimestampDetector.civilFromDays(days)
        return "\(pad(c.year, 4))-\(pad(c.month, 2))-\(pad(c.day, 2)) "
            + "\(pad(rem / 3600, 2)):\(pad((rem % 3600) / 60, 2)):\(pad(rem % 60, 2))"
            + ".\(pad(millis, 3))"
    }

    private static func pad(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    private static func stamp() -> String {
        let now = Date().timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT())
        let rem = Int(now) % 86_400
        return "\(pad(rem / 3600, 2))\(pad((rem % 3600) / 60, 2))\(pad(rem % 60, 2))"
    }
}
