import SwiftUI

/// Previews use each palette's actual UI colors, independently of the current theme.
struct ThemePickerView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.codecTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    paletteSection("Dark", options: codecThemes.filter { !$0.isLight })
                    paletteSection("Light", options: codecThemes.filter(\.isLight))
                }
                .padding(20)
                .padding(.bottom, 12)
            }
            .background(theme.bg)
            .navigationTitle("Palettes")
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

    private func paletteSection(_ title: String, options: [CodecTheme]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(theme.text)
                Text(options.count.formatted())
                    .font(.subheadline)
                    .foregroundStyle(theme.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(options) { option in
                    let selected = themeStore.themeID == option.id
                    Button {
                        // Palette changes should take effect together, without a color crossfade.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            themeStore.themeID = option.id
                        }
                    } label: {
                        paletteCard(option, selected: selected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(option.name)
                    .accessibilityValue(option.isLight ? "Light palette" : "Dark palette")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityHint("Applies this palette throughout Codec")
                }
            }
        }
    }

    private func paletteCard(_ option: CodecTheme, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Text(option.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(option.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    Circle()
                        .fill(selected ? option.accent : option.surface)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(option.accentText)
                    } else {
                        Circle().stroke(option.border, lineWidth: 1)
                    }
                }
                .frame(width: 20, height: 20)
            }

            HStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(option.accent)
                    .frame(width: 30, height: 30)
                    .background(option.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Capsule()
                        .fill(option.text)
                        .frame(height: 4)
                    Capsule()
                        .fill(option.muted)
                        .frame(maxWidth: 32)
                        .frame(height: 3)
                }

                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(option.accent)
            }
            .padding(8)
            .background(option.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(12)
        .background(option.bg)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(selected ? option.accent : theme.border, lineWidth: selected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
