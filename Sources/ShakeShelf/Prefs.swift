import Foundation

enum Prefs {
    private static let autoAddKey = "autoAddScreenshots"
    private static let removeAfterDragKey = "removeAfterDragOut"

    /// New screenshots saved to disk are automatically added to the shelf.
    static var autoAddScreenshots: Bool {
        get { UserDefaults.standard.object(forKey: autoAddKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoAddKey) }
    }

    /// Items are removed from the shelf after being dragged out successfully.
    static var removeAfterDragOut: Bool {
        get { UserDefaults.standard.bool(forKey: removeAfterDragKey) }
        set { UserDefaults.standard.set(newValue, forKey: removeAfterDragKey) }
    }

    /// The configured shortcut, or nil when the user cleared it. An action
    /// that has never been touched gets its default so shortcuts work out of
    /// the box; a cleared one is stored explicitly so it stays cleared.
    static func hotKey(for action: HotKeyAction) -> HotKeyCombo? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: clearedKey(action)) as? Bool != true else { return nil }
        guard let data = defaults.data(forKey: comboKey(action)),
              let combo = try? JSONDecoder().decode(HotKeyCombo.self, from: data) else {
            return action.defaultCombo
        }
        return combo
    }

    static func setHotKey(_ combo: HotKeyCombo?, for action: HotKeyAction) {
        let defaults = UserDefaults.standard
        guard let combo else {
            defaults.set(true, forKey: clearedKey(action))
            defaults.removeObject(forKey: comboKey(action))
            return
        }
        defaults.set(false, forKey: clearedKey(action))
        defaults.set(try? JSONEncoder().encode(combo), forKey: comboKey(action))
    }

    private static func comboKey(_ action: HotKeyAction) -> String { "hotKeyCombo.\(action.rawValue)" }
    private static func clearedKey(_ action: HotKeyAction) -> String { "hotKeyCleared.\(action.rawValue)" }
}
