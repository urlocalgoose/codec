import SwiftUI

/// First-run screen: server URL + optional token, deck style.
struct ConnectView: View {
    @Environment(\.loudTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player

    var body: some View {
        @Bindable var app = app

        ScrollView {
            VStack {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(theme.accentText)
                            .frame(width: 52, height: 52)
                            .background(theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        Text("Codec")
                            .font(LoudFont.hand(28))
                            .foregroundStyle(theme.text)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("iPhone")
                            .foregroundStyle(theme.accent)

                        Text("Connect your Codec server.")
                            .font(.system(size: 38, weight: .heavy))
                            .foregroundStyle(theme.text)

                        Text("Paste the URL printed by the sync server. Add the auth token if the server uses one.")
                            .font(.system(size: 16, weight: .semibold))
                            .lineSpacing(2)
                            .foregroundStyle(theme.muted)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Sync server")
                        deckField(icon: "server.rack") {
                            TextField("http://192.168.1.20:8787", text: $app.serverURLString)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Auth token (optional)")
                        deckField(icon: "key") {
                            SecureField("LOUD_AUTH_TOKEN", text: $app.token)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }

                    Button {
                        Task {
                            await app.connect()
                            app.syncPlayer(player)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if app.connection == .connecting {
                                ProgressView()
                                    .tint(theme.accentText)
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                            }
                            Text(app.connection == .connecting ? "Connecting" : "Connect")
                        }
                        .font(.system(size: 14, weight: .heavy))
                    }
                    .buttonStyle(DeckButtonStyle(primary: true))
                    .disabled(app.connection == .connecting || app.serverURLString.trimmingCharacters(in: .whitespaces).isEmpty)

                    if !app.errorMessage.isEmpty {
                        Text(app.errorMessage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.danger)
                    }
                }
                .padding(24)
                .background(theme.panel.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.line, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.38), radius: 48, x: 0, y: 24)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        }
        .background(theme.bg.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
    }

    private func deckField(icon: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(theme.subtle)
                .frame(width: 22)

            content()
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.text)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(theme.bg.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(theme.line, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 0, x: 0, y: 2)
    }
}
