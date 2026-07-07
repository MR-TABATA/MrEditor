import AppKit

/// エディタ本文の等幅フォントとサイズ（グローバル・永続化）。
/// ⌘+ / ⌘- / ⌘0 でサイズを変え、起動をまたいで保持する。
enum EditorFont {
    static let defaultSize: CGFloat = 12
    static let minSize: CGFloat = 9
    static let maxSize: CGFloat = 28
    private static let sizeKey = "MrEditor.fontSize"

    private static var size: CGFloat = {
        let v = UserDefaults.standard.double(forKey: sizeKey)
        return v > 0 ? CGFloat(v) : defaultSize
    }()

    static var currentSize: CGFloat { size }

    /// サイズを設定（min/max にクランプし永続化）。クランプ後の値を返す。
    @discardableResult
    static func setSize(_ newSize: CGFloat) -> CGFloat {
        let clamped = min(max(minSize, newSize), maxSize)
        size = clamped
        UserDefaults.standard.set(Double(clamped), forKey: sizeKey)
        return clamped
    }

    static func current() -> NSFont {
        if let f = NSFont(name: "SF Mono", size: size) { return f }
        if let f = NSFont(name: "Menlo", size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
