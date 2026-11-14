import Foundation

/// 構造化表示の列の並び順と幅を、名前を付けて保存したもの（ビュープリセット・C9）。
///
/// 一致判定(シグネチャ)は `mode` が同じ、かつ `columnOrder` の**集合**が現在の列名の
/// 集合と完全一致(順不同)。1つでも列名が違えば別ファイル形状とみなす ──
/// 「同じ列構成の複数ファイル(店舗別・日別エクスポート等)に効く」という元アイデアの動機そのもの。
///
/// `mode` は `StructuredMode`(core)の rawValue で持つ。**core に `Codable` を足さず**
/// ViewPreset 自身でシリアライズできるようにするため。
struct ViewPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var modeRawValue: String
    /// 保存時点の並び(key のリスト)。
    var columnOrder: [String]
    var columnWidths: [String: Int]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, mode: StructuredMode,
         columnOrder: [String], columnWidths: [String: Int], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.modeRawValue = mode.rawValue
        self.columnOrder = columnOrder
        self.columnWidths = columnWidths
        self.createdAt = createdAt
    }

    var mode: StructuredMode? { StructuredMode(rawValue: modeRawValue) }

    /// いま見えている列構成に、このプリセットを一覧へ出してよいか。
    func matches(mode: StructuredMode, columns: [String]) -> Bool {
        modeRawValue == mode.rawValue && Set(columnOrder) == Set(columns)
    }
}
