import Foundation

/// 遠隔のフォルダを歩くための、向こうで動かす文字列と、その出力の読み方。
///
/// 一覧は `ls` を**使わない**。`ls -l` の書式は BSD と GNU で違い、`ls -F` の印は名前と
/// 区別がつかない（`a*` という名のファイルがある）。シェルの組み込みだけで「フォルダか」
/// を 1 件ずつ確かめれば、シンボリックリンクの先がフォルダでも正しく分かる。
extension RemoteFile {

    /// 宛先が何か。繋いだ直後に 1 回だけ訊く。
    public enum Kind: Equatable {
        case file
        case directory
        /// 無い。親フォルダに入る権限が無い場合も、シェルからは同じに見える。
        case missing
        /// ファイルはあるが読めない。
        case unreadable
        /// 通常のファイルでもフォルダでもない（デバイス・パイプ等）。
        case special
    }

    /// 宛先の種類を 1 回で訊く。ログインシェルが POSIX でなくても動くよう `sh -c` に包む。
    static func kindCommand(_ path: String) -> String {
        let script = """
        p=\(shellQuote(path))
        if [ -d "$p" ]; then echo kind:dir
        elif [ -f "$p" ]; then if [ -r "$p" ]; then echo kind:file; else echo kind:unreadable; fi
        elif [ -e "$p" ]; then echo kind:special
        else echo kind:missing; fi
        """
        return "sh -c \(shellQuote(script))"
    }

    /// `kindCommand` の出力から種類を読む。読めなければ nil（古い向こうでも落とさない）。
    static func parseKind(_ output: String) -> Kind? {
        for raw in output.split(whereSeparator: \.isNewline) {
            switch raw.trimmingCharacters(in: .whitespaces) {
            case "kind:dir":        return .directory
            case "kind:file":       return .file
            case "kind:unreadable": return .unreadable
            case "kind:special":    return .special
            case "kind:missing":    return .missing
            default:                continue
            }
        }
        return nil
    }

    /// 一覧に載せる上限。これを越えたら打ち切って、打ち切ったことを人に伝える。
    static let listLimit = 5000
    /// 名前検索で返す上限。
    static let findLimit = 500

    /// フォルダの直下を 1 往復で列挙する。`d 名前` / `f 名前`、打ち切ったら最後に `t`。
    ///
    /// `printf '%s\n'` を使うのは、`echo` が実装によって `\` を解釈するため。
    /// `.[!.]* ..?* *` は `.` と `..` を除いた隠しファイルを含む全件を選ぶ定番の書き方。
    /// 当たりが無いときはパターンがそのまま残るので `-e` / `-L` で捨てる。
    static func listCommand(_ path: String) -> String {
        let script = """
        cd \(shellQuote(path)) 2>/dev/null || { echo 'cannot enter the folder' >&2; exit 2; }
        n=0
        for f in .[!.]* ..?* *; do
          [ -e "$f" ] || [ -L "$f" ] || continue
          n=$((n+1))
          if [ $n -gt \(listLimit) ]; then echo t; break; fi
          if [ -d "$f" ]; then printf '%s\\n' "d $f"; else printf '%s\\n' "f $f"; fi
        done
        """
        return "sh -c \(shellQuote(script))"
    }

    /// 一覧の 1 件。
    public struct DirectoryEntry: Equatable {
        public let name: String
        public let isDirectory: Bool
    }

    /// `listCommand` の出力を読む。
    public static func parseList(_ output: String) -> (entries: [DirectoryEntry], truncated: Bool) {
        var entries: [DirectoryEntry] = []
        var truncated = false
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line == "t" { truncated = true; continue }
            guard line.count > 2 else { continue }
            let kind = line.first
            let name = String(line.dropFirst(2))
            guard kind == "d" || kind == "f" else { continue }
            entries.append(DirectoryEntry(name: name, isDirectory: kind == "d"))
        }
        return (entries, truncated)
    }

    /// `-iname` のパターンに載せる前に、ワイルドカードの意味を持つ文字を無効にする。
    /// 人が打つのは「この文字を含む名前」であって、パターンではない。
    static func escapeGlob(_ term: String) -> String {
        var out = ""
        for c in term {
            if c == "\\" || c == "*" || c == "?" || c == "[" { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// 名前に `term` を含むファイルを、フォルダの下から探す（大小無視）。
    /// 本文は見ない ―― **フォルダ全体の本文検索は Pro の線**で、ここは「名前で開く」だけ。
    static func findCommand(_ root: String, term: String) -> String {
        let pattern = "*" + escapeGlob(term) + "*"
        let script = """
        cd \(shellQuote(root)) 2>/dev/null || { echo 'cannot enter the folder' >&2; exit 2; }
        find . \\( -type f -o -type l \\) -iname \(shellQuote(pattern)) 2>/dev/null | head -n \(findLimit + 1)
        """
        return "sh -c \(shellQuote(script))"
    }

    /// `find` の出力（`./a/b`）を相対パスに直す。上限を越えていたら打ち切りを伝える。
    public static func parseFind(_ output: String) -> (paths: [String], truncated: Bool) {
        var paths = output.split(separator: "\n", omittingEmptySubsequences: true).map { raw -> String in
            let s = String(raw)
            return s.hasPrefix("./") ? String(s.dropFirst(2)) : s
        }
        let truncated = paths.count > findLimit
        if truncated { paths.removeLast(paths.count - findLimit) }
        return (paths, truncated)
    }
}
