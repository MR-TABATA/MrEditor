import AppKit

/// エディタ本文の等幅フォント（種別・サイズ）をグローバルに保持し永続化する。
/// ⌘+ / ⌘- / ⌘0 でサイズを変え、環境設定(⌘,)で種別＋サイズを選べる。
/// 変更は `.mrEditorFontChanged` で全ウィンドウのビューアへ通知する。
enum EditorFont {
    static let defaultSize: CGFloat = 12
    static let minSize: CGFloat = 9
    static let maxSize: CGFloat = 28
    private static let sizeKey = "MrEditor.fontSize"
    private static let nameKey = "MrEditor.fontName"

    /// フォント名が未指定・生成不能のときに先頭から試す既定候補。
    private static let fallbackNames = ["SF Mono", "Menlo", "Monaco", "Courier"]

    private static var size: CGFloat = {
        let v = UserDefaults.standard.double(forKey: sizeKey)
        return v > 0 ? CGFloat(v) : defaultSize
    }()

    /// 選択中のフォント名（nil＝システム既定の等幅にフォールバック）。
    private static var name: String? = UserDefaults.standard.string(forKey: nameKey)

    static var currentSize: CGFloat { size }
    static var currentName: String? { name }

    /// サイズを設定（min/max にクランプし永続化・通知）。クランプ後の値を返す。
    @discardableResult
    static func setSize(_ newSize: CGFloat) -> CGFloat {
        let clamped = min(max(minSize, newSize), maxSize)
        size = clamped
        UserDefaults.standard.set(Double(clamped), forKey: sizeKey)
        NotificationCenter.default.post(name: .mrEditorFontChanged, object: nil)
        return clamped
    }

    /// フォント名を設定（nil＝システム既定へ戻す）。永続化・通知する。
    static func setName(_ newName: String?) {
        name = newName
        let d = UserDefaults.standard
        if let n = newName { d.set(n, forKey: nameKey) } else { d.removeObject(forKey: nameKey) }
        NotificationCenter.default.post(name: .mrEditorFontChanged, object: nil)
    }

    static func current() -> NSFont {
        if let n = name, let f = NSFont(name: n, size: size) { return f }
        for n in fallbackNames { if let f = NSFont(name: n, size: size) { return f } }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// 選択肢として提示する等幅フォントファミリ名（表示名でソート）。
    /// システム全体から `isFixedPitch` のものを拾い、既定候補も併せて含める。
    static func availableMonospaceFamilies() -> [String] {
        var names = Set<String>()
        for family in NSFontManager.shared.availableFontFamilies {
            if let f = NSFont(name: family, size: defaultSize), f.isFixedPitch {
                names.insert(family)
            }
        }
        for n in fallbackNames where NSFont(name: n, size: defaultSize) != nil {
            names.insert(n)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

extension Notification.Name {
    /// エディタフォント（種別・サイズ）が変わったとき（開いている全ビューアへ反映）。
    static let mrEditorFontChanged = Notification.Name("MrEditor.fontChanged")
}
