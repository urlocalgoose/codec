import SwiftUI

/// First-run connection. Cached libraries open directly into the music tabs.
struct ConnectView: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @FocusState private var focusedField: Field?
    @ScaledMetric(relativeTo: .body) private var fieldIconWidth: CGFloat = 22

    private enum Field: Hashable {
        case server, token
    }

    private var isConnecting: Bool { app.connection == .connecting || app.isReconnecting }
    private var connectionMessage: String {
        if !app.errorMessage.isEmpty { return app.errorMessage }
        return app.connectionIssue?.title ?? ""
    }
    private var canConnect: Bool {
        !isConnecting && !app.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        @Bindable var app = app

        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    brand

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect to your library")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(theme.text)
                            .accessibilityAddTraits(.isHeader)

                        Text("Enter your server address and auth token to get started.")
                            .font(.body)
                            .foregroundStyle(theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 8) {
                            fieldLabel("Server address")
                            field(icon: "link", focused: focusedField == .server) {
                                TextField("Server address", text: $app.serverURLString,
                                          prompt: Text(verbatim: "https://music.example.com").foregroundStyle(theme.muted))
                                    .keyboardType(.URL)
                                    .submitLabel(.next)
                                    .focused($focusedField, equals: .server)
                                    .onSubmit { focusedField = .token }
                                    .accessibilityLabel("Server address")
                                    .accessibilityIdentifier("connect.server")
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            fieldLabel("Auth token")
                            field(icon: "key", focused: focusedField == .token) {
                                SecureField("Auth token", text: $app.token,
                                            prompt: Text("Paste your token").foregroundStyle(theme.muted))
                                    .submitLabel(.go)
                                    .focused($focusedField, equals: .token)
                                    .onSubmit(connect)
                                    .privacySensitive()
                                    .accessibilityLabel("Auth token")
                                    .accessibilityIdentifier("connect.token")
                            }
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isConnecting)

                    VStack(alignment: .leading, spacing: 16) {
                        if !connectionMessage.isEmpty {
                            Label {
                                Text(connectionMessage)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "exclamationmark.circle")
                            }
                            .font(.subheadline)
                            .foregroundStyle(theme.danger)
                            .accessibilityIdentifier("connect.error")
                        }

                        Button(action: connect) {
                            HStack(spacing: 10) {
                                if isConnecting {
                                    ProgressView()
                                        .tint(theme.accentText)
                                }
                                Text(isConnecting ? "Connecting…" : "Connect")
                            }
                            .font(.body.weight(.semibold))
                            .foregroundStyle(canConnect || isConnecting ? theme.accentText : theme.muted)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .padding(.vertical, 15)
                            .padding(.horizontal, 16)
                            .background(canConnect || isConnecting ? theme.accent : theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canConnect)
                        .accessibilityIdentifier("connect.submit")

                        Text("Use the same server and token as your other devices.")
                            .font(.footnote)
                            .foregroundStyle(theme.muted)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 24) {
                            Link("Privacy Policy", destination: URL(string: "https://codec.codie.sh/privacy.html")!)
                            Link("Support", destination: URL(string: "https://codec.codie.sh/support.html")!)
                        }
                        .font(.footnote)
                        .frame(minHeight: 44)
                    }
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(theme.bg.ignoresSafeArea())
        .tint(theme.accent)
    }

    private var brand: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                brandMark
                brandName.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 16) {
                brandMark
                brandName
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var brandMark: some View {
        Image("CodecLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder((theme.isLight ? Color.black : Color.white).opacity(0.1), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    private var brandName: some View {
        Text("Codec")
            .font(.largeTitle.weight(.black))
            .tracking(-1)
            .foregroundStyle(theme.text)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.muted)
    }

    private func field<Content: View>(icon: String, focused: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(theme.muted)
                .frame(width: fieldIconWidth)
                .accessibilityHidden(true)
            content()
                .font(.body)
                .foregroundStyle(theme.text)
        }
        .padding(16)
        .frame(minHeight: 54)
        .background(theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? theme.accent : theme.border, lineWidth: 1)
        }
    }

    private func connect() {
        guard canConnect else { return }
        focusedField = nil
        Task {
            await app.connect()
            app.syncPlayer(player)
        }
    }
}
