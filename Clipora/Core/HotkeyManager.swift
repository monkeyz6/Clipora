import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleHistoryPanel = Self(
        "toggleHistoryPanel", default: .init(.j, modifiers: [.command])
    )
    static let toggleFavoritesPanel = Self(
        "toggleFavoritesPanel", default: .init(.j, modifiers: [.command, .shift])
    )
}

final class HotkeyManager {

    func bind(
        onHistory: @escaping () -> Void,
        onFavorites: @escaping () -> Void
    ) {
        KeyboardShortcuts.onKeyDown(for: .toggleHistoryPanel, action: onHistory)
        KeyboardShortcuts.onKeyDown(for: .toggleFavoritesPanel, action: onFavorites)
    }
}
