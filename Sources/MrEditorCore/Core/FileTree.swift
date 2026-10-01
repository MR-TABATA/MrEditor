import Foundation

/// ツリーの 1 件。**手元と遠隔で同じ型を使う**（見せ方を二重に持たない）。
/// `NSOutlineView` が同一性で追うため `NSObject`。
final class FileNode: NSObject {
    /// 画面に出す名前（検索結果では、起点からの相対パス）。
    let name: String
    /// 手元ならファイルシステムのパス、遠隔なら向こうの絶対パス。
    let path: String
    let isDirectory: Bool
    /// `nil` ＝ まだ読んでいない。空配列 ＝ 読んだが空。
    var children: [FileNode]?
    var isLoading = false
    /// 一覧が上限で打ち切られていたか。
    var truncated = false

    init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }
}

/// フォルダの中身を返す係。手元は `FileManager`、遠隔は ssh。
/// **同期で、呼び出し側が裏のキューから呼ぶ**（遠隔は遅く、画面を止めてはいけない）。
protocol DirectoryProvider {
    func list(_ path: String) throws -> (nodes: [FileNode], truncated: Bool)
    /// 名前に `term` を含むファイルを、`root` の下から探す。大小は無視。
    func search(root: String, term: String) throws -> (nodes: [FileNode], truncated: Bool)
    func describe(_ error: Error) -> String
}

enum FileTreeOrder {
    /// フォルダを先に、あとは名前順（数字は数として、大小は無視）。
    static func sorted(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - 手元

struct LocalDirectoryProvider: DirectoryProvider {

    static let listLimit = 5000
    static let searchLimit = 500

    func list(_ path: String) throws -> (nodes: [FileNode], truncated: Bool) {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: path)
        var nodes: [FileNode] = []
        for name in names.prefix(Self.listLimit) {
            let full = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            // シンボリックリンクは先を見る（フォルダへのリンクはフォルダとして歩ける）
            fm.fileExists(atPath: full, isDirectory: &isDir)
            nodes.append(FileNode(name: name, path: full, isDirectory: isDir.boolValue))
        }
        return (FileTreeOrder.sorted(nodes), names.count > Self.listLimit)
    }

    func search(root: String, term: String) throws -> (nodes: [FileNode], truncated: Bool) {
        let fm = FileManager.default
        // 列挙の URL は実体のパス（`/tmp` → `/private/tmp`）で返るので、起点も実体にそろえる。
        // そろえないと相対パスの切り出しが外れる。
        // （`resolvingSymlinksInPath` は `/private` を勝手に落とすので使わず、`realpath` で実体を取る）
        let realRoot = URL(fileURLWithPath: Self.realPath(root))
        guard let walker = fm.enumerator(
            at: realRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return ([], false) }

        var found: [FileNode] = []
        var truncated = false
        let rootPath = realRoot.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for case let url as URL in walker {
            // `.git` の中は名前を探す対象にしない（オブジェクトの名前が大量に当たるだけ）
            if url.lastPathComponent == ".git" { walker.skipDescendants(); continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            guard url.lastPathComponent.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            else { continue }
            if found.count >= Self.searchLimit { truncated = true; break }
            let rel = url.path.hasPrefix(rootPrefix) ? String(url.path.dropFirst(rootPrefix.count)) : url.path
            found.append(FileNode(name: rel, path: url.path, isDirectory: false))
        }
        return (found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, truncated)
    }

    func describe(_ error: Error) -> String { error.localizedDescription }

    /// 実体のパス。解決できなければ元のまま。
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - 遠隔

struct RemoteDirectoryProvider: DirectoryProvider {
    let host: String

    /// 向こうの絶対パスをつなぐ。
    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    func list(_ path: String) throws -> (nodes: [FileNode], truncated: Bool) {
        let r = try RemoteSession.listDirectory(host: host, path: path)
        let nodes = r.entries.map {
            FileNode(name: $0.name, path: Self.join(path, $0.name), isDirectory: $0.isDirectory)
        }
        return (FileTreeOrder.sorted(nodes), r.truncated)
    }

    func search(root: String, term: String) throws -> (nodes: [FileNode], truncated: Bool) {
        let r = try RemoteSession.findFiles(host: host, root: root, term: term)
        let nodes = r.paths.map { FileNode(name: $0, path: Self.join(root, $0), isDirectory: false) }
        return (nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, r.truncated)
    }

    func describe(_ error: Error) -> String { RemoteWindowController.describe(error) }
}
