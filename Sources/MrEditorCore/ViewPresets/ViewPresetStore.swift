import Foundation

/// ビュープリセットの永続化。`UserDefaults.standard` に JSON 配列で持つ。
///
/// 書き出しファイル・共有URLはv1では作らない。
final class ViewPresetStore {
    private static let defaultsKey = "MrEditor.viewPresets"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAll() -> [ViewPreset] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let presets = try? JSONDecoder().decode([ViewPreset].self, from: data) else { return [] }
        return presets
    }

    private func save(_ presets: [ViewPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// いまの列構成に一致するもの(新しい順)。
    func matching(mode: StructuredMode, columns: [String]) -> [ViewPreset] {
        loadAll()
            .filter { $0.matches(mode: mode, columns: columns) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func add(name: String, mode: StructuredMode, order: [String], widths: [String: Int]) -> ViewPreset {
        var all = loadAll()
        let preset = ViewPreset(name: name, mode: mode, columnOrder: order, columnWidths: widths)
        all.append(preset)
        save(all)
        return preset
    }

    func rename(id: UUID, to newName: String) {
        var all = loadAll()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].name = newName
        save(all)
    }

    func delete(id: UUID) {
        save(loadAll().filter { $0.id != id })
    }
}
