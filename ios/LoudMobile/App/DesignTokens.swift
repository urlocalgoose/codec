import Observation
import SwiftUI

/// One desktop theme, ported 1:1 from src/app.css. The full list lives in
/// Themes.generated.swift (regenerate with `bun run gen:ios-themes`).
struct LoudTheme: Identifiable, Equatable {
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

    static let fallback = loudThemes[0]
}

@MainActor
@Observable
final class ThemeStore {
    private static let storageKey = "loud.theme"

    var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: Self.storageKey) }
    }

    var theme: LoudTheme {
        loudThemes.first { $0.id == themeID } ?? .fallback
    }

    init() {
        themeID = UserDefaults.standard.string(forKey: Self.storageKey) ?? LoudTheme.fallback.id
    }
}

private struct LoudThemeKey: EnvironmentKey {
    static let defaultValue = LoudTheme.fallback
}

extension EnvironmentValues {
    var loudTheme: LoudTheme {
        get { self[LoudThemeKey.self] }
        set { self[LoudThemeKey.self] = newValue }
    }
}

enum LoudFont {
    static func hand(_ size: CGFloat) -> Font {
        .custom("Codie Hand", size: size)
    }
}

// MARK: - Deck keys
//
// The transport is a tape deck. Momentary keys (skip, actions) travel 5pt
// down while held and spring back; latching keys (play, shuffle, repeat)
// stay seated 4pt down while their state is on — the same travel the
// desktop encodes as --button-press-y / --button-latched-y.

/// The exact desktop keycap: the dark bottom edge is INSIDE the key
/// (inset 0 -5px), with a 1px glint along the top face. Pressing collapses
/// the edge to 1px while the whole key travels down — no detached drop
/// shadow anywhere.
private struct DeckKeySurface: ViewModifier {
    let theme: LoudTheme
    let down: Bool
    let fill: Color
    let leftRadius: Bool
    let rightRadius: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(fill)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.buttonShadow)
                    .frame(height: down ? 1 : 5)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(theme.glint)
                    .frame(height: 1)
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: leftRadius ? 3 : 0,
                    bottomLeadingRadius: leftRadius ? 3 : 0,
                    bottomTrailingRadius: rightRadius ? 3 : 0,
                    topTrailingRadius: rightRadius ? 3 : 0
                )
            )
    }
}

/// Momentary key: down while pressed, springs back on release.
/// Travel: 5pt (the desktop's --button-press-y).
struct DeckButtonStyle: ButtonStyle {
    @Environment(\.loudTheme) private var theme

    let primary: Bool
    let leftRadius: Bool
    let rightRadius: Bool

    init(primary: Bool = false, leftRadius: Bool = true, rightRadius: Bool = true) {
        self.primary = primary
        self.leftRadius = leftRadius
        self.rightRadius = rightRadius
    }

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        return configuration.label
            .foregroundStyle(primary ? theme.accentText : theme.muted)
            .modifier(DeckKeySurface(
                theme: theme,
                down: down,
                fill: primary ? theme.accent : (down ? theme.buttonActive : theme.button),
                leftRadius: leftRadius,
                rightRadius: rightRadius
            ))
            .offset(y: down ? 5 : 0)
            .animation(.easeOut(duration: 0.09), value: down)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: down) { _, pressed in
                pressed
            }
    }
}

/// Latching key: stays seated while `isOn`, like the play key on a cassette
/// deck. Seated travel is 4pt (--button-latched-y); the latch lands with a
/// heavier clunk than a momentary press.
struct DeckToggleButtonStyle: ButtonStyle {
    @Environment(\.loudTheme) private var theme

    let isOn: Bool
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        let down = isOn || configuration.isPressed
        let travel: CGFloat = configuration.isPressed ? 5 : (isOn ? 4 : 0)
        return configuration.label
            .foregroundStyle(primary ? theme.accentText : (isOn ? theme.text : theme.muted))
            .modifier(DeckKeySurface(
                theme: theme,
                down: down,
                fill: primary ? theme.accent : (down ? theme.buttonActive : theme.button),
                leftRadius: true,
                rightRadius: true
            ))
            .offset(y: travel)
            .animation(.easeOut(duration: 0.09), value: down)
            .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.9), trigger: isOn)
    }
}
