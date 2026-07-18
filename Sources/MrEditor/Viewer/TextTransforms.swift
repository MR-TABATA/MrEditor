import Foundation

/// 編集ツールボックスの純粋なテキスト変換（String→String）。
/// バックエンド（NSTextView / PieceTable）に依存せず、両ペインから同じロジックを使う。
enum TextTransform: Int, CaseIterable {
    case uppercase
    case lowercase
    case titlecase
    case togglecase

    /// メニュー項目のローカライズキー。
    var localizationKey: String {
        switch self {
        case .uppercase:  return "menu.format.uppercase"
        case .lowercase:  return "menu.format.lowercase"
        case .titlecase:  return "menu.format.titlecase"
        case .togglecase: return "menu.format.togglecase"
        }
    }

    /// 選択文字列に変換を適用して返す。
    func apply(_ s: String) -> String {
        switch self {
        case .uppercase:  return s.uppercased()
        case .lowercase:  return s.lowercased()
        case .titlecase:  return s.capitalized
        case .togglecase: return String(s.map { c in
            c.isUppercase ? Character(c.lowercased()) :
            c.isLowercase ? Character(c.uppercased()) : c
        })
        }
    }
}
