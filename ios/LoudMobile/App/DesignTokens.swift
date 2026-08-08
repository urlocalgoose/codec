import SwiftUI

enum LoudColor {
    static let bg = Color(red: 15.0 / 255.0, green: 32.0 / 255.0, blue: 24.0 / 255.0)
    static let panel = Color(red: 20.0 / 255.0, green: 41.0 / 255.0, blue: 31.0 / 255.0)
    static let panel2 = Color(red: 27.0 / 255.0, green: 57.0 / 255.0, blue: 41.0 / 255.0)
    static let surface = Color(red: 40.0 / 255.0, green: 73.0 / 255.0, blue: 54.0 / 255.0)
    static let surfaceHover = Color(red: 51.0 / 255.0, green: 91.0 / 255.0, blue: 68.0 / 255.0)
    static let button = Color(red: 33.0 / 255.0, green: 63.0 / 255.0, blue: 47.0 / 255.0)
    static let buttonPressed = Color(red: 53.0 / 255.0, green: 104.0 / 255.0, blue: 72.0 / 255.0)
    static let text = Color(red: 238.0 / 255.0, green: 247.0 / 255.0, blue: 223.0 / 255.0)
    static let muted = Color(red: 187.0 / 255.0, green: 209.0 / 255.0, blue: 177.0 / 255.0)
    static let subtle = Color(red: 131.0 / 255.0, green: 161.0 / 255.0, blue: 126.0 / 255.0)
    static let accent = Color(red: 114.0 / 255.0, green: 194.0 / 255.0, blue: 143.0 / 255.0)
    static let accentText = Color(red: 7.0 / 255.0, green: 21.0 / 255.0, blue: 13.0 / 255.0)
    static let danger = Color(red: 255.0 / 255.0, green: 143.0 / 255.0, blue: 127.0 / 255.0)
    static let line = Color(red: 238.0 / 255.0, green: 247.0 / 255.0, blue: 223.0 / 255.0).opacity(0.065)
    static let glint = Color.white.opacity(0.04)
    static let shadow = Color.black.opacity(0.32)
}

enum LoudFont {
    static func hand(_ size: CGFloat) -> Font {
        .custom("Codie Hand", size: size)
    }
}

struct DeckButtonStyle: ButtonStyle {
    let primary: Bool
    let leftRadius: Bool
    let rightRadius: Bool

    init(primary: Bool = false, leftRadius: Bool = true, rightRadius: Bool = true) {
        self.primary = primary
        self.leftRadius = leftRadius
        self.rightRadius = rightRadius
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? LoudColor.accentText : LoudColor.muted)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(primary ? LoudColor.accent : (configuration.isPressed ? LoudColor.buttonPressed : LoudColor.button))
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: leftRadius ? 3 : 0,
                    bottomLeadingRadius: leftRadius ? 3 : 0,
                    bottomTrailingRadius: rightRadius ? 3 : 0,
                    topTrailingRadius: rightRadius ? 3 : 0
                )
            )
            .shadow(color: configuration.isPressed ? .clear : LoudColor.shadow, radius: 0, x: 0, y: 5)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(LoudColor.shadow)
                    .frame(height: configuration.isPressed ? 1 : 0)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .offset(y: configuration.isPressed ? 5 : 0)
            .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
    }
}
