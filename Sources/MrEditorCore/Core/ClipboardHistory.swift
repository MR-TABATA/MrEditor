import AppKit

/// 直近のクリップボードの中身を、アプリが起きているあいだだけ憶えておく（簡易版・無料コア）。
///
/// **永続化しない。** 終了すれば消える ── パスワードマネージャからコピーした中身を
/// ディスクへ平文で残すと、法人で使うには最悪の形になる。
/// **`org.nspasteboard.ConcealedType` を尊重する**（1Password 等がパスワードコピー時に立てる
/// フラグ。nspasteboard.org の業界慣行）。無視すると「パスワードが履歴に並ぶアプリ」になる。
///
/// `NSPasteboard.general.changeCount` を軽くポーリングするだけなので、常駐中は
/// 他アプリでコピーしたものも拾える（特別な権限は要らない）。機能は絞る ──
/// テキストのみ・件数上限・検索やピン留めは無し（「ポチしたらずらっと並ぶ」で足りる）。
/// メモリ `clipboard-history-corporate-angle` の合意どおり。
public final class ClipboardHistory {
    public struct Entry: Equatable {
        public let text: String
        public let date: Date
        public init(text: String, date: Date) {
            self.text = text
            self.date = date
        }
    }

    /// 憶えておく件数の上限。古いものから捨てる。
    public var limit = 20
    public private(set) var entries: [Entry] = []
    /// 増えた・消えたときに呼ばれる（メインスレッド）。
    public var onChange: (() -> Void)?

    private var lastChangeCount: Int
    private var timer: Timer?
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    public init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    deinit { stop() }

    public func start(interval: TimeInterval = 0.5) {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // メニュー表示中・スクロール中も止めない
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 実際にポーリングする 1 回ぶん。`NSPasteboard.general` を読むだけの薄い口で、
    /// 判定の本体は `record` に渡す（テストは `record` を直接呼び、本物の pasteboard を汚さない）。
    func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        record(types: pb.types ?? [], text: pb.string(forType: .string))
    }

    /// 純粋な判定＋記録。テスト対象の本体。
    func record(types: [NSPasteboard.PasteboardType], text: String?) {
        guard !types.contains(Self.concealedType) else { return }
        guard let text, !text.isEmpty else { return }
        guard entries.first?.text != text else { return }   // 同じ内容の連続コピーは増やさない
        entries.insert(Entry(text: text, date: Date()), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        onChange?()
    }

    public func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        onChange?()
    }
}
