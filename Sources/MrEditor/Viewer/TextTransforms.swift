import Foundation

/// 編集ツールボックスの純粋なテキスト変換（String→String）。
/// バックエンド（NSTextView / PieceTable）に依存せず、両ペインから同じロジックを使う。
enum TextTransform: Int, CaseIterable {
    // ケース変換
    case uppercase
    case lowercase
    case titlecase
    case togglecase
    // エンコード／デコード
    case urlEncode
    case urlDecode
    case base64Encode
    case base64Decode

    /// ケース変換グループ（書式メニューの第1グループ）。
    static let caseGroup: [TextTransform] = [.uppercase, .lowercase, .titlecase, .togglecase]
    /// エンコード／デコードグループ（書式メニューの第2グループ）。
    static let encodingGroup: [TextTransform] = [.urlEncode, .urlDecode, .base64Encode, .base64Decode]

    /// メニュー項目のローカライズキー。
    var localizationKey: String {
        switch self {
        case .uppercase:    return "menu.format.uppercase"
        case .lowercase:    return "menu.format.lowercase"
        case .titlecase:    return "menu.format.titlecase"
        case .togglecase:   return "menu.format.togglecase"
        case .urlEncode:    return "menu.format.urlEncode"
        case .urlDecode:    return "menu.format.urlDecode"
        case .base64Encode: return "menu.format.base64Encode"
        case .base64Decode: return "menu.format.base64Decode"
        }
    }

    /// 選択文字列に変換を適用して返す。`nil` は変換不能（不正な入力など）＝呼び出し側はビープして本文を変えない。
    func apply(_ s: String) -> String? {
        switch self {
        case .uppercase:  return s.uppercased()
        case .lowercase:  return s.lowercased()
        case .titlecase:  return s.capitalized
        case .togglecase: return String(s.map { c in
            c.isUppercase ? Character(c.lowercased()) :
            c.isLowercase ? Character(c.uppercased()) : c
        })
        case .urlEncode:  return s.addingPercentEncoding(withAllowedCharacters: Self.urlUnreserved)
        case .urlDecode:  return s.removingPercentEncoding
        case .base64Encode: return Data(s.utf8).base64EncodedString()
        case .base64Decode:
            // 改行入りの折り返し Base64 も通す（不明文字は無視）。復号後が UTF-8 でなければ nil。
            guard let data = Data(base64Encoded: s, options: .ignoreUnknownCharacters),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        }
    }

    /// RFC 3986 の unreserved（これ以外を % エンコードする）。
    private static let urlUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
