import AppKit
import Sparkle

/// 更新の仕組みの入口。Sparkle を包む（試験で差し替えられるように、口は小さくしてある）。
@MainActor
protocol UpdaterBackend: AnyObject {
    /// 自動で新版を確かめるか。
    var automaticallyChecksForUpdates: Bool { get set }
    /// 起動の最後に 1 度。
    func start()
    /// メニューからの明示的な確認。
    func checkForUpdates()
}

/// 本物の Sparkle。
@MainActor
final class SparkleBackend: UpdaterBackend {
    private let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                          updaterDelegate: nil, userDriverDelegate: nil)

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func start() { controller.startUpdater() }
    func checkForUpdates() { controller.checkForUpdates(nil) }
}

/// 自動更新。署名（EdDSA）の検証・ダウンロード・入れ替え・再起動は Sparkle に任せる。
///
/// **更新の行き先はバンドルが名乗る**（Info.plist の `SUFeedURL`。`scripts/make_app.sh` が、
/// 配布版のバンドル ID にだけ書く）。名乗っていなければ、更新確認そのものをしない ——
/// 開発ビルドや別のバンドルに、配布版の更新を勧めさせないため。
@MainActor
final class AppUpdater {
    static let shared = AppUpdater(backend: AppUpdater.isAvailable ? SparkleBackend() : nil)

    /// 更新確認ができるか（＝バンドルが feed を宣言しているか）。
    nonisolated static var isAvailable: Bool { AppInfo.updateFeedURL != nil }

    private let backend: UpdaterBackend?

    init(backend: UpdaterBackend?) {
        self.backend = backend
    }

    /// 起動の最後に 1 度だけ呼ぶ。
    ///
    /// **自動チェックの有無は、Sparkle 自身の保存値が唯一の本物。** 起動のたびに、こちらから書かない
    /// （Sparkle の説明: 利用者の選択を上書きし、確認のスケジュールをリセットしてしまう）。
    /// ただし、1.28.0 までの自前の保存値が残っていれば、**1 度だけ**引き継いで、消す
    /// （「確認しない」を選んだ人が、更新で、勝手に「確認する」へ戻らないように）。
    func start() {
        guard let backend else { return }
        if let legacy = AppSettings.legacyAutomaticUpdateChecks {
            backend.automaticallyChecksForUpdates = legacy
            AppSettings.removeLegacyAutomaticUpdateChecks()
        }
        backend.start()
    }

    /// 環境設定の表示に使う、いまの値（Sparkle の保存値）。feed を宣言しない .app では false。
    var automaticChecks: Bool {
        backend?.automaticallyChecksForUpdates ?? false
    }

    /// メニュー「アップデートを確認…」。結果（新版あり・最新・失敗）は Sparkle が画面に出す。
    func checkForUpdates() {
        backend?.checkForUpdates()
    }

    /// 環境設定のチェックボックスから（利用者が選んだときだけ書く）。
    func setAutomaticChecks(_ enabled: Bool) {
        backend?.automaticallyChecksForUpdates = enabled
    }
}
