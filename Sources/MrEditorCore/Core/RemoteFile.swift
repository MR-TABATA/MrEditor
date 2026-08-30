import Foundation

/// `ssh host:/path` の向こうにある 1 本を、**範囲読み**で触る係（B5）。
///
/// **落として開くのは無し**（2026-08-30 決定・notes/ROADMAP.md M6）。落としてから
/// ローカルで開くなら `scp` で済み、アプリが持つ理由がない。意味は `tail -f` / `more`。
///
/// **実装方式は `/usr/bin/ssh` に shell out。** `ssh_config` の全解釈・ProxyJump・多段・
/// 2FA・ssh-agent・Match/Include がタダで付く ＝「ターミナルで繋がるなら繋がる」。
/// libssh2 / swift-nio-ssh は却下（`ssh_config` の自前解釈で ProxyJump/Include が地獄、
/// 鍵管理の責任と CVE 追従義務を負う）。**秘密鍵は保存しない。**
///
/// **向こう側のコマンドに依存する。** BusyBox の組み込み機器・制限シェル・`rbash` では
/// 欠けることがあり、そこだけ「ターミナルで繋がるなら繋がる」の約束が破れる。だから
/// 繋いだ直後に一度だけ能力を検出し、無いものは機能を畳む ── **畳んだ理由も出す。**
/// 黙って消えると壊れたように見える。
public enum RemoteFile {

    // MARK: - 宛先

    /// `ssh host:/path` / `host:/path` を割ったもの。**ここでは接続しない。**
    public struct Target: Equatable {
        /// `user@host` あるいは `host`。ssh へそのまま渡す（`ssh_config` の Host 別名も通る）。
        public let host: String
        /// 向こう側の絶対パス。
        public let path: String

        public init(host: String, path: String) {
            self.host = host
            self.path = path
        }
    }

    /// 文字列が遠隔の指定なら割る。そうでなければ nil ＝ ローカルのパスとして扱う。
    ///
    /// 受けるのは `ssh host:/path` と `host:/path` の 2 つだけ。**相対パスは受けない** ──
    /// 向こうのカレントディレクトリは人には見えず、`~` の展開もシェル任せで揺れるので、
    /// 「開いたつもりの場所」と実際がズレる。
    ///
    /// Windows のドライブレター（`C:\...`）と取り違えないよう、host は 2 文字以上を要求する。
    public static func parse(_ text: String) -> Target? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("ssh ") { s = String(s.dropFirst(4)).trimmingCharacters(in: .whitespaces) }

        guard let colon = s.firstIndex(of: ":") else { return nil }
        let host = String(s[s.startIndex..<colon])
        let path = String(s[s.index(after: colon)...])

        guard host.count >= 2, !host.contains("/"), !host.contains(" ") else { return nil }
        guard path.hasPrefix("/") else { return nil }
        return Target(host: host, path: path)
    }

    // MARK: - 向こうで動かすコマンド

    /// 文字列を単引用符で包む。**向こうはシェルなので、包まないとパスが命令になる。**
    /// 単引用符自身は `'\''` で閉じて開き直す（POSIX sh の唯一の逃げ方）。
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 総バイト数を訊く。`wc -c` は POSIX で、実装は通常 fstat に落ちる。
    /// `stat` は BSD と GNU で書式が違うので使わない。
    static func sizeCommand(_ path: String) -> String {
        "wc -c < \(shellQuote(path))"
    }

    /// `wc -c` の出力を数に直す。
    ///
    /// **BSD の `wc` は先頭を空白で詰める**（`"    4096\n"`）。GNU は詰めない。
    /// 向こうがどちらかは分からないので、両端の空白と改行を落としてから読む。
    /// 数として読めなければ nil ＝ **サイズは「不明」**。0 とは書かない（取れなかったの意味が違う）。
    static func parseSize(_ output: String) -> Int? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return nil }
        return Int(trimmed)
    }

    /// 任意位置の範囲読み。**`tail -c +N | head -c L`。**
    ///
    /// `dd skip=` はブロック境界に揃える必要があり、`iflag=skip_bytes` は GNU 専用。
    /// `tail -c +N` はバイト単位で POSIX、BusyBox にもある。`+N` は **1 始まり**なので
    /// オフセットに 1 を足す（ここを間違えると 1 バイトずれた本文を平然と表示する）。
    static func readCommand(_ path: String, offset: Int, length: Int) -> String {
        let q = shellQuote(path)
        // 先頭からなら tail を挟まない（大きなファイルで tail に数え直させない）
        if offset <= 0 { return "head -c \(length) < \(q)" }
        return "tail -c +\(offset + 1) < \(q) | head -c \(length)"
    }

    /// 末尾から N バイト。**サイズが訊けないときの逃げ道。**
    /// 訊けるなら範囲読み（`count - N ..< count`）で足りるので、そちらを使う。
    static func tailCommand(_ path: String, bytes: Int) -> String {
        "tail -c \(bytes) < \(shellQuote(path))"
    }

    /// **向こうで絞る。** これが遠隔で一番効く一手 ――
    /// 10GB を 1 バイトも転送せずに、一致行と行番号だけが返る。
    ///
    /// - `context` は `grep -C` 相当（前後の行）。**当たりの意味は、たいてい直前の行にある。**
    /// - 正規表現は `grep -E`（POSIX 拡張）。**先読み・後読みは使えない** ――
    ///   手元の検索は対応しているので、ここだけ狭い。狭いことは人に伝える。
    /// - 固定文字列なら `-F`。`.` や `*` を含む語をそのまま探せる。
    static func grepCommand(
        _ path: String,
        pattern: String,
        context: Int = 0,
        ignoreCase: Bool = false,
        regex: Bool = false,
        maxMatches: Int = 5000
    ) -> String {
        var flags = ["-n"]                       // 行番号は必須。これが無いと飛べない
        flags.append(regex ? "-E" : "-F")
        if ignoreCase { flags.append("-i") }
        if context > 0 { flags.append("-C \(context)") }
        if maxMatches > 0 { flags.append("-m \(maxMatches)") }
        // 一致が無ければ grep は 1 で終わる。ここでは「無かった」は失敗ではないので握る。
        return "grep \(flags.joined(separator: " ")) -e \(shellQuote(pattern)) \(shellQuote(path)) || true"
    }

    /// `grep -n -C` の 1 行。行番号と、それが当たりか前後かを持つ。
    public struct Match: Equatable {
        public let line: Int          // 1 始まり（grep の流儀）
        public let isMatch: Bool      // false ＝ -C で付いてきた前後の行
        public let text: String
    }

    /// `grep -n` の出力を割る。
    ///
    /// **当たりは `123:本文`、前後は `123-本文`。** まとまりの区切りは `--` の行。
    /// 本文にも `:` は普通に入るので、**最初の区切りだけ**で割る（そこを間違えると
    /// URL やタイムスタンプを含む行が壊れる）。
    public static func parseGrep(_ output: String) -> [Match] {
        var out: [Match] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty || line == "--" { continue }

            // 先頭の数字を読む
            var digits = ""
            var idx = line.startIndex
            while idx < line.endIndex, line[idx].isNumber {
                digits.append(line[idx])
                idx = line.index(after: idx)
            }
            guard !digits.isEmpty, idx < line.endIndex, let number = Int(digits) else { continue }

            let sep = line[idx]
            guard sep == ":" || sep == "-" else { continue }
            let text = String(line[line.index(after: idx)...])
            out.append(Match(line: number, isMatch: sep == ":", text: text))
        }
        return out
    }

    /// 能力検出。**1 回の接続で全部訊く**（1 コマンドにつき 1 往復させない）。
    /// 在るものだけが行として返る ＝ 無いものは黙って落ちる。
    static func capabilityCommand() -> String {
        let names = ["wc", "head", "tail", "grep"]
        return names.map { "command -v \($0) >/dev/null 2>&1 && echo \($0)" }.joined(separator: "; ")
    }

    /// 向こうに在ったコマンド。無いものがあれば、その機能を畳む材料になる。
    public struct Capabilities: Equatable {
        public let hasWc: Bool
        public let hasHead: Bool
        public let hasTail: Bool
        public let hasGrep: Bool

        /// 開くことすらできない組み合わせ。`head` が無いと 1 バイトも取り出せない。
        public var canRead: Bool { hasHead }
        /// 総バイト数が訊けるか。無ければ行数も進捗も「不明」で出す（0 とは書かない）。
        public var canSize: Bool { hasWc }
        /// 末尾追従。
        public var canFollow: Bool { hasTail }
        /// 向こうで絞る（フィルタ表示・検索）。無ければ手元へ引いて絞ることになる。
        public var canFilter: Bool { hasGrep }

        /// 畳んだ機能を、理由つきで人へ出すための文言。畳むものが無ければ空。
        public var degraded: [String] {
            var out: [String] = []
            if !hasWc { out.append("行数と総サイズは「不明」で出します（向こうに wc がありません）") }
            if !hasTail { out.append("末尾追従（tail -f）は使えません（向こうに tail がありません）") }
            if !hasGrep { out.append("絞り込みは手元で行います（向こうに grep がありません）") }
            return out
        }

        public init(hasWc: Bool, hasHead: Bool, hasTail: Bool, hasGrep: Bool) {
            self.hasWc = hasWc
            self.hasHead = hasHead
            self.hasTail = hasTail
            self.hasGrep = hasGrep
        }

        /// `capabilityCommand()` の出力（1 行 1 コマンド名）から組む。
        public static func parse(_ output: String) -> Capabilities {
            let found = Set(output.split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespaces)
            })
            return Capabilities(
                hasWc: found.contains("wc"),
                hasHead: found.contains("head"),
                hasTail: found.contains("tail"),
                hasGrep: found.contains("grep")
            )
        }
    }

    // MARK: - ssh の引数

    /// Unix ドメインソケットのパス長の上限（`sun_path`）。macOS は 104。
    /// **ここを越えると ssh は `unix_listener: path too long` で即死する。**
    static let socketPathLimit = 104
    /// ssh が `%C` を展開したぶん（40 桁）と、自分で足す一時接尾辞（`.XXXXXXXXXXXXXXXX`）。
    static let controlPathExpansion = 40 - "%C".count + 17

    /// `ControlMaster` の置き場。**接続を多重化して、範囲読みのたびに繋ぎ直さない。**
    /// スクロールのたびに 3 往復の握手をすると、遅延が全部このアプリのせいに見える。
    ///
    /// **`NSTemporaryDirectory()` は使えない。** macOS では `/var/folders/…` と長く、
    /// `%C` の展開を足すとソケットのパス長上限を越える（実 ssh で初めて出た。手元の
    /// `/bin/sh` に通す試験では分からない）。短くて自分だけが書ける場所を自前で作る。
    static func controlPath() -> String {
        let dir = URL(fileURLWithPath: "/tmp/mreditor-\(getuid())", isDirectory: true)
        // 0700。/tmp は誰でも書けるので、ここを緩めるとソケットの置き場を横取りされる。
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir.appendingPathComponent("s-%C").path
    }

    /// 多重化を諦めるべきか。**越えていたら畳む** ―― ControlMaster は速さのための
    /// 仕掛けであって、無くても読める。長さで死ぬくらいなら、遅くても繋がるほうがいい。
    static func controlPathFits(_ path: String) -> Bool {
        path.utf8.count + controlPathExpansion <= socketPathLimit
    }

    /// `/usr/bin/ssh` に渡す引数。**`ssh_config` は殺さない** ── 足すのは多重化と
    /// 「端末を要求しない」ことだけで、Host 別名も ProxyJump もユーザーの設定のまま通す。
    ///
    /// `BatchMode` は付けない。付けるとパスワード認証と未知のホスト鍵で即座に失敗する。
    /// そこは `SSH_ASKPASS` で GUI から訊く（端末が無いため）。
    static func sshArguments(host: String, remoteCommand: String) -> [String] {
        var args: [String] = []
        let path = controlPath()
        if controlPathFits(path) {
            args += [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(path)",
                "-o", "ControlPersist=60",
            ]
        }
        args += [
            "-T",                       // 疑似端末を割り当てない（こちらは人ではない）
            host,
            remoteCommand,
        ]
        return args
    }
}
