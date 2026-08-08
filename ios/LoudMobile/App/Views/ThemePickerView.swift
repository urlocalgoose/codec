import SwiftUI

/// The desktop's theme modal, iOS-native: same swatch chips, same themes.
struct ThemePickerView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.loudTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(loudThemes) { option in
                        Button {
                            themeStore.themeID = option.id
                        } label: {
                            themeChip(option)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .padding(.bottom, 40)
            }
            .background(theme.bg)
            .navigationTitle("Theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: themeStore.themeID)
    }

    private func themeChip(_ option: LoudTheme) -> some View {
        let selected = themeStore.themeID == option.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(option.swatch[index])
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(theme.border, lineWidth: 1))
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(theme.accent)
                }
            }

            Text(option.name)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(selected ? theme.text : theme.muted)
                .lineLimit(1)
        }
        .padding(12)
        .background(option.swatch[1])
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? theme.accent : theme.border, lineWidth: selected ? 2 : 1)
        )
    }
}
