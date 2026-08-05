import AppKit

/// メインウィンドウのツールバー。
///
/// **既定に並べる 6 つがこのアプリの「顔」**である、という前提で作っている。
/// 起動しただけの人にとってメニューとショートカットは存在しないのと同じで、
/// 構造化表示・フィルタ・比較・末尾追従・AI 診断は「ここに出ていなければ無い」。
/// だからコピー／保存／行ジャンプ／フォント拡縮は **既定に入れない**。
/// ⌘F・⌘S は誰でも知っていて発見性の価値が無く、入れると「よくあるエディタ」の顔になる。
///
/// 並び順にも意味がある。狭い窓では右から順に » に畳まれるので、
/// **右端の AI 診断が最初に消え、左端の構造化表示が最後まで残る**。
///
/// 置ける全部（`allowedItemIdentifiers`）と既定で並ぶ分（`defaultItemIdentifiers`）は別で、
/// 「カスタマイズ…」のパレットには載るが既定では出ない、という状態を作れる。
/// 将来の Pro 機能はこの **既定オフ**（allowed に入れて default に入れない）で出す。
/// 買っていない人の画面に押せないボタンを並べない、という線引きのため。
extension NSToolbarItem.Identifier {
    static let mrSidebar     = NSToolbarItem.Identifier("mr.sidebar")
    static let mrStructured  = NSToolbarItem.Identifier("mr.structured")
    static let mrFilter      = NSToolbarItem.Identifier("mr.filter")
    static let mrCompare     = NSToolbarItem.Identifier("mr.compare")
    static let mrFollow      = NSToolbarItem.Identifier("mr.follow")
    static let mrAIDiagnose  = NSToolbarItem.Identifier("mr.aiDiagnose")
}

/// ツールバーの組み立てを引き受ける delegate。動作は全て `MainWindowController` に委譲する。
final class MainToolbarDelegate: NSObject, NSToolbarDelegate {
    private weak var controller: MainWindowController?

    init(controller: MainWindowController) {
        self.controller = controller
        super.init()
    }

    /// 既定で並ぶ分。左端のサイドバー開閉は macOS の作法（Finder/Mail/Xcode）なので
    /// 「顔」のコストには数えない。区切りを挟んで、その右が本体。
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.mrSidebar, .space,
         .mrStructured, .mrFilter, .mrCompare, .mrFollow, .mrAIDiagnose]
    }

    /// カスタマイズのパレットに載る全部。既定に無いものも、欲しい人は自分で引き出せる。
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.mrSidebar, .mrStructured, .mrFilter, .mrCompare, .mrFollow, .mrAIDiagnose,
         .space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .mrSidebar:
            return button(id, label: L("toolbar.sidebar"), symbol: "sidebar.left",
                          action: #selector(MainWindowController.toolbarToggleSidebar(_:)))

        case .mrStructured:
            // 5 択（オフ + CSV/TSV/NDJSON/JSON）なので押しボタンにできない。
            // メニュー付きにして、メニュー自体はメニューバー側と同じ意味の項目を持たせる。
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = L("menu.structured")
            item.paletteLabel = L("menu.structured")
            item.toolTip = L("menu.structured")
            item.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)
            item.showsIndicator = true
            item.menu = structuredMenu()
            return item

        case .mrFilter:
            return button(id, label: L("toolbar.filter"), symbol: "line.3.horizontal.decrease",
                          action: #selector(MainWindowController.toolbarShowFilter(_:)))

        case .mrCompare:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = L("menu.compare")
            item.paletteLabel = L("menu.compare")
            item.toolTip = L("menu.compare")
            item.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
            item.showsIndicator = true
            item.menu = compareMenu()
            return item

        case .mrFollow:
            return button(id, label: L("menu.follow"), symbol: "arrow.down.to.line",
                          action: #selector(MainWindowController.toolbarToggleFollow(_:)))

        case .mrAIDiagnose:
            return button(id, label: L("ai.menu.errorCause"), symbol: "sparkles",
                          action: #selector(MainWindowController.toolbarDiagnoseWithAI(_:)))

        default:
            return nil
        }
    }

    // MARK: - 組み立ての小道具

    private func button(_ id: NSToolbarItem.Identifier, label: String,
                        symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = controller
        item.action = action
        item.isBordered = true
        return item
    }

    /// 構造化表示のメニュー。チェックはメニューが開かれる直前に `MainWindowController` が付け直す。
    private func structuredMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = controller
        let off = NSMenuItem(title: L("menu.structured.off"),
                             action: #selector(MainWindowController.toolbarSetStructuredMode(_:)),
                             keyEquivalent: "")
        off.tag = -1
        off.target = controller
        menu.addItem(off)
        menu.addItem(.separator())
        for (i, mode) in StructuredMode.allCases.enumerated() {
            let item = NSMenuItem(title: L("menu.structured.\(mode.rawValue)"),
                                  action: #selector(MainWindowController.toolbarSetStructuredMode(_:)),
                                  keyEquivalent: "")
            item.tag = i
            item.target = controller
            menu.addItem(item)
        }
        return menu
    }

    /// 比較のメニュー。メニューバーの「比較（diff）」と同じ 4 つの入口。
    private func compareMenu() -> NSMenu {
        let menu = NSMenu()
        let entries: [(String, Selector)] = [
            (L("menu.compare.files"),    #selector(MainWindowController.toolbarCompareFiles(_:))),
            (L("menu.compare.openDocs"), #selector(MainWindowController.toolbarCompareOpenDocuments(_:))),
            (L("menu.compare.clipboard"), #selector(MainWindowController.toolbarCompareWithClipboard(_:))),
            (L("menu.compare.url"),      #selector(MainWindowController.toolbarCompareWithURL(_:))),
        ]
        for (title, action) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = controller
            menu.addItem(item)
        }
        return menu
    }
}
