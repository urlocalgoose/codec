import Observation
import SwiftUI

/// One desktop theme, ported 1:1 from src/app.css. The full list lives in
/// Themes.generated.swift (regenerate with `bun run gen:ios-themes`).
struct CodecTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let bg: Color
    let panel: Color
    let panel2: Color
    let surface: Color
    let surfaceHover: Color
    let border: Color
    let line: Color
    let text: Color
    let muted: Color
    let subtle: Color
    let accent: Color
    let accentHover: Color
    let danger: Color
    let button: Color
    let buttonHover: Color
    let buttonActive: Color
    let buttonShadow: Color
    let accentText: Color
    let glint: Color
    let swatch: [Color]
    let isLight: Bool

    static let fallback = codecThemes[0]
}

@MainActor
@Observable
final class ThemeStore {
    private static let storageKey = "codec.theme"
    private static let legacyStorageKey = "loud.theme"

    var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: Self.storageKey) }
    }

    var theme: CodecTheme {
        codecThemes.first { $0.id == themeID } ?? .fallback
    }

    init() {
        themeID = UserDefaults.standard.string(forKey: Self.storageKey)
            ?? UserDefaults.standard.string(forKey: Self.legacyStorageKey)
            ?? CodecTheme.fallback.id
    }
}

private struct CodecThemeKey: EnvironmentKey {
    static let defaultValue = CodecTheme.fallback
}

extension EnvironmentValues {
    var codecTheme: CodecTheme {
        get { self[CodecThemeKey.self] }
        set { self[CodecThemeKey.self] = newValue }
    }
}

enum CodecFont {
    static func hand(_ size: CGFloat) -> Font {
        .custom("Codie Hand", size: size)
    }
}
