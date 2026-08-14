import Foundation

/// ディスク上のファイルの「版」。外部変更を見分けるための最小の指紋。
///
/// **内容は読まない。** 10GB のファイルを 1 秒ごとに読み直すわけにはいかないので、
/// `stat(2)` が返すサイズ・更新時刻・inode だけで「変わった」を判定する。
/// inode を含めるのは、多くのエディタが**別ファイルへ書いて置き換える**（atomic save）ため。
/// 置き換えではサイズも更新時刻も同じことがありうるが、inode は必ず変わる。
struct FileStamp: Equatable {
    var size: Int64
    /// 更新時刻（1970 起点の秒。ナノ秒まで見る＝1 秒以内の連続変更も取りこぼさない）。
    var modified: TimeInterval
    var inode: UInt64

    /// いまのディスクの状態を読む。ファイルが無ければ nil。
    static func read(_ url: URL) -> FileStamp? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        let mtime = TimeInterval(st.st_mtimespec.tv_sec)
            + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
        return FileStamp(size: Int64(st.st_size), modified: mtime, inode: UInt64(st.st_ino))
    }
}

/// 監視 1 件の状態。
struct FileWatchEntry: Equatable {
    var url: URL
    /// このアプリが取り込み済みの版（＝いま表示しているはずの内容）。
    var known: FileStamp?
    /// 変化を見つけたが、まだ落ち着いていない版。
    var pending: FileStamp?
    /// `pending` が続いた回数。
    var pendingTicks: Int = 0
}

/// 開いているファイルが**アプリの外**で書き換わったかを見張る。
///
/// 1 ファイルにつき 1 tick で `stat` 1 回。内容を読まないので、10GB を開いていても
/// コストは無視できる。**取り込みの判断はしない**（誰に何をさせるかは呼び出し側の仕事）。
final class ExternalChangeWatcher {
    /// 変化を見つけたとき。メインスレッドで呼ばれる。
    var onChange: ((ObjectIdentifier) -> Void)?
    /// 見に行く間隔。安定判定に 2 tick 使うので、体感は 1 秒前後。
    var interval: TimeInterval = 0.5

    /// 書き込み途中を掴まないため、**同じ版を 2 回続けて見るまで待つ**。
    /// ただしログのように書かれ続けるファイルは落ち着かないので、この回数で観念して通す。
    static let forceAfterTicks = 4

    private(set) var entries: [ObjectIdentifier: FileWatchEntry] = [:]
    private var timer: Timer?

    deinit { stop() }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // スクロール中・メニュー表示中も止めない
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 監視対象を「いまのディスクの状態は取り込み済み」として登録／更新する。
    /// ファイルを開いた直後・保存した直後・読み込み直した直後に呼ぶ
    /// （**自分の書き込みを外部変更と誤認しない**ための唯一の仕掛け）。
    func note(key: ObjectIdentifier, url: URL) {
        entries[key] = FileWatchEntry(url: url, known: FileStamp.read(url))
    }

    func forget(key: ObjectIdentifier) {
        entries.removeValue(forKey: key)
    }

    /// 監視リストを開いているファイルの一覧に合わせる。
    /// **すでに見ているものの版は触らない**（ここで版を取り直すと、取り込み前の変更を
    /// 「知っている版」に格上げしてしまい、変更を握り潰す）。
    func sync(_ items: [(key: ObjectIdentifier, url: URL)]) {
        let live = Set(items.map(\.key))
        for key in entries.keys where !live.contains(key) { entries.removeValue(forKey: key) }
        for item in items {
            if entries[item.key]?.url != item.url { note(key: item.key, url: item.url) }
        }
    }

    /// 1 回分の見回り。テストからは直接呼ぶ（タイマーを待たない）。
    func tick() {
        for (key, var entry) in entries {
            let changed = Self.decide(&entry, current: FileStamp.read(entry.url))
            entries[key] = entry
            if changed { onChange?(key) }
        }
    }

    /// 1 件・1 tick 分の判定（純関数。時計もファイルも触らない）。取り込むべきなら true。
    ///
    /// - ファイルが消えている（`current == nil`）間は**何もしない**。非 atomic な書き手は
    ///   書いている最中に一瞬消えるので、ここで騒ぐと空の内容を読み込みかねない。
    ///   `known` を残しておくので、書き終わって現れた時点で差分として拾える。
    static func decide(_ entry: inout FileWatchEntry,
                       current: FileStamp?,
                       forceAfter: Int = ExternalChangeWatcher.forceAfterTicks) -> Bool {
        guard let current else {
            entry.pending = nil
            entry.pendingTicks = 0
            return false
        }
        if current == entry.known {
            entry.pending = nil
            entry.pendingTicks = 0
            return false
        }
        entry.pendingTicks += 1
        // 同じ版を 2 回見た（＝書き終わった）か、待ちが長引いた（＝書かれ続けている）。
        if current == entry.pending || entry.pendingTicks >= forceAfter {
            entry.known = current
            entry.pending = nil
            entry.pendingTicks = 0
            return true
        }
        entry.pending = current
        return false
    }
}