import AppKit

/// GitHub Releases を見て新しい版が出ていないか調べ、出ていたら知らせる。
///
/// **置き換えはしない。** ダイアログから dmg のリリースページをブラウザで開くだけで、
/// ダウンロード・検証・入れ替えはユーザーの手に委ねる。その場で自動インストールする
/// 仕組み（Sparkle 等）は Developer ID 署名を入れてから検討する。署名の無いアプリを
/// 自動で置き換えるのは、配布経路として筋が悪い。
enum UpdateChecker {

    /// 判明した最新リリース。
    struct Release {
        /// タグから取り出したバージョン（"v1.2" なら "1.2"）。
        let version: String
        /// リリースページ（dmg が無い場合はここを開く）。
        let pageURL: URL
        /// 配布物の直リンク（あれば）。
        let dmgURL: URL?
    }

    enum CheckError: Error { case network(Error), badResponse }

    private static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/MR-TABATA/MrEditor/releases/latest")!

    // MARK: - バージョン比較（純粋関数・テスト対象）

    /// "v1.2" / "1.2.3" / "1.2-beta" を数値の並びへ。数字以外は 0 とみなす。
    static func components(_ version: String) -> [Int] {
        version
            .drop(while: { !$0.isNumber })          // 先頭の "v" などを捨てる
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// `a` が `b` より新しいか。桁数が違っても比較できる（"1.0" > "0.7"、"1.0.1" > "1.0"）。
    static func isNewer(_ a: String, than b: String) -> Bool {
        let lhs = components(a), rhs = components(b)
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - 取得

    /// 最新リリースを取り出す。完了は必ずメインスレッドで呼ぶ。
    static func fetchLatest(_ completion: @escaping (Result<Release, CheckError>) -> Void) {
        var req = URLRequest(url: latestReleaseAPI, timeoutInterval: 10)
        // GitHub API は User-Agent を要求する。無いと 403 が返る。
        req.setValue("MrEditor/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: req) { data, response, error in
            let result: Result<Release, CheckError>
            if let error {
                result = .failure(.network(error))
            } else if let release = data.flatMap(parse) ,
                      (response as? HTTPURLResponse)?.statusCode == 200 {
                result = .success(release)
            } else {
                result = .failure(.badResponse)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// GitHub の JSON から必要な3点だけ取り出す（テストのため分離）。
    static func parse(_ data: Data) -> Release? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let page = (root["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }

        let assets = root["assets"] as? [[String: Any]] ?? []
        let dmg = assets
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.hasSuffix(".dmg") }
            .flatMap(URL.init(string:))

        let version = String(tag.drop(while: { !$0.isNumber }))
        guard !version.isEmpty else { return nil }
        return Release(version: version, pageURL: page, dmgURL: dmg)
    }

    // MARK: - UI

    /// 更新を調べて必要ならダイアログを出す。
    /// - Parameter manual: メニューから明示的に呼ばれたか。`true` なら
    ///   「最新です」も失敗も知らせる。`false`（起動時の自動チェック）は
    ///   新版があるときだけ喋る。黙って失敗するのが正しい。
    static func check(manual: Bool) {
        if !manual {
            guard AppSettings.automaticUpdateChecks, shouldCheckToday() else { return }
            AppSettings.lastUpdateCheck = Date()
        }
        fetchLatest { result in
            switch result {
            case .success(let release):
                if isNewer(release.version, than: AppInfo.version) {
                    presentAvailable(release)
                } else if manual {
                    presentUpToDate()
                }
            case .failure:
                if manual { presentFailure() }
            }
        }
    }

    /// 自動チェックは 1 日 1 回まで。起動のたびに GitHub を叩かない。
    private static func shouldCheckToday() -> Bool {
        guard let last = AppSettings.lastUpdateCheck else { return true }
        return Date().timeIntervalSince(last) >= 24 * 60 * 60
    }

    private static func presentAvailable(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = L("update.availableTitle", AppInfo.name, release.version)
        alert.informativeText = L("update.availableMessage", AppInfo.version)
        alert.addButton(withTitle: L("update.download"))   // .alertFirstButtonReturn
        alert.addButton(withTitle: L("update.later"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.dmgURL ?? release.pageURL)
        }
    }

    private static func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = L("update.upToDateTitle", AppInfo.name, AppInfo.version)
        alert.informativeText = L("update.upToDateMessage")
        alert.runModal()
    }

    private static func presentFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("update.failedTitle")
        alert.informativeText = L("update.failedMessage")
        alert.runModal()
    }
}
