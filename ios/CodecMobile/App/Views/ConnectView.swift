import SwiftUI

/// Branch-based first-run help. Cached libraries open directly into music.
struct ConnectView: View {
    @Environment(\.codecTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @FocusState private var focusedField: Field?
    @AccessibilityFocusState private var headingFocused: Bool
    @ScaledMetric(relativeTo: .body) private var fieldIconWidth: CGFloat = 22
    @State private var selectedScreen: Screen?

    enum Screen: String, CaseIterable { case welcome, connect, setup, explain }
    private enum Field: Hashable { case server, token }

    init(initialScreen: Screen? = nil) {
        _selectedScreen = State(initialValue: initialScreen)
    }

    private var isConnecting: Bool { app.connection == .connecting || app.isReconnecting }
    private var connectionMessage: String {
        if !app.errorMessage.isEmpty { return app.errorMessage }
        return app.connectionIssue?.title ?? ""
    }
    private var screen: Screen {
        selectedScreen ?? Self.initialScreen(server: app.serverURLString, token: app.token,
                                             connecting: isConnecting, message: connectionMessage)
    }
    static func initialScreen(server: String, token: String, connecting: Bool, message: String) -> Screen {
        server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !connecting && message.isEmpty ? .welcome : .connect
    }
    private var canConnect: Bool {
        !isConnecting && !app.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var title: String {
        switch screen {
        case .welcome: "Welcome"
        case .connect: "Connect to your library"
        case .setup: "Set up a server"
        case .explain: "How Codec works"
        }
    }
    private var introduction: String? {
        switch screen {
        case .welcome: "Codec plays music from a server you host."
        case .connect: "Enter your server address and auth token."
        case .setup: "Your server stores your music and makes it available to Codec."
        case .explain: nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        brand.id("connect.top")

                        if screen != .welcome {
                            Button { navigate(to: .welcome) } label: {
                                Label("Back to welcome", systemImage: "chevron.left")
                                    .font(.subheadline.weight(.medium))
                                    .frame(minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isConnecting)
                            .accessibilityIdentifier("connect.back")
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(title)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(theme.text)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityFocused($headingFocused)
                                .accessibilityIdentifier("connect.heading")
                            if let introduction { explanation(introduction) }
                        }

                        screenContent
                            .id(screen)
                            .transition(.opacity)

                        footer
                    }
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height, alignment: .center)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: screen) {
                    scroll.scrollTo("connect.top", anchor: .top)
                    Task { @MainActor in
                        await Task.yield()
                        headingFocused = true
                    }
                }
            }
        }
        .background(theme.bg.ignoresSafeArea())
        .tint(theme.accent)
    }

    @ViewBuilder private var screenContent: some View {
        switch screen {
        case .welcome:
            VStack(spacing: 12) {
                choice("I have a server", detail: "Connect to your music.", icon: "link", screen: .connect)
                choice("I need to set one up", detail: "Start with the setup guide.", icon: "externaldrive", screen: .setup)
                choice("I'm confused", detail: "See how Codec works.", icon: "questionmark.circle", screen: .explain)
            }
        case .connect:
            connectionForm
        case .setup:
            VStack(alignment: .leading, spacing: 24) {
                explanation("Run it on a computer you keep on, or on a cloud server. The setup guide covers installation and adding your music.")
                Link(destination: URL(string: "https://codec.codie.sh/docs/hosting.html")!) {
                    primaryLabel("Open setup guide", icon: "arrow.up.right")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the setup guide in your browser")
                .accessibilityIdentifier("connect.guide")
                secondary("I have my server details", screen: .connect)
            }
        case .explain:
            VStack(alignment: .leading, spacing: 24) {
                explanation("Codec is an open-source, self-hosted music player.")
                explanationSection("What that means", text: "The code is public, so you can read it, change it, and run it yourself. Your library lives on a server you control, at home or in the cloud.")
                explanationSection("Why self-host", text: "Keep your music in one place and listen across your devices, with control over your files and who can access them.")
                explanationSection("Get started", text: "Install the Codec server on Linux, add your music, then connect the app or web player with the server address and auth token.")
                Link(destination: URL(string: "https://codec.codie.sh/docs/hosting.html")!) {
                    primaryLabel("Open setup guide", icon: "arrow.up.right")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the setup guide in your browser")
                .accessibilityIdentifier("connect.guide")
                secondary("I have a server", screen: .connect)
                Link("Visit the Codec website", destination: URL(string: "https://codec.codie.sh")!)
                    .font(.footnote)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("connect.website")
            }
        }
    }

    private var connectionForm: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: 24) {
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

            if !connectionMessage.isEmpty {
                Label { Text(connectionMessage).fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "exclamationmark.circle") }
                    .font(.subheadline)
                    .foregroundStyle(theme.danger)
                    .accessibilityIdentifier("connect.error")
            }
            Button(action: connect) {
                HStack(spacing: 10) {
                    if isConnecting { ProgressView().tint(theme.accentText) }
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
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) { footerLinks }
            VStack(alignment: .leading, spacing: 0) { footerLinks }
        }
        .font(.footnote)
    }
    @ViewBuilder private var footerLinks: some View {
        Link("Privacy Policy", destination: URL(string: "https://codec.codie.sh/privacy.html")!)
            .frame(minHeight: 44)
        Link("Support", destination: URL(string: "https://codec.codie.sh/support.html")!)
            .frame(minHeight: 44)
    }
    private func explanation(_ text: String) -> some View {
        Text(text).font(.body).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
    }
    private func explanationSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.body.weight(.semibold)).foregroundStyle(theme.text)
                .accessibilityAddTraits(.isHeader)
            explanation(text)
        }
    }
    private func choice(_ title: String, detail: String, icon: String, screen: Screen) -> some View {
        Button { navigate(to: screen) } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3.weight(.medium))
                    .frame(width: fieldIconWidth)
                    .foregroundStyle(theme.muted)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(theme.text)
                    Text(detail).font(.subheadline).foregroundStyle(theme.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.subtle)
                    .accessibilityHidden(true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.border, lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connect.choice.\(screen.rawValue)")
    }
    private func secondary(_ title: String, screen: Screen) -> some View {
        Button { navigate(to: screen) } label: {
            Text(title).font(.body.weight(.medium)).frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connect.next.\(screen.rawValue)")
    }
    private func primaryLabel(_ title: String, icon: String? = nil) -> some View {
        HStack(spacing: 10) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            if let icon { Image(systemName: icon).accessibilityHidden(true) }
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(theme.accentText)
        .frame(maxWidth: .infinity, minHeight: 24)
        .padding(.vertical, 15)
        .padding(.horizontal, 16)
        .background(theme.accent)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    private func navigate(to screen: Screen) {
        guard !isConnecting else { return }
        focusedField = nil
        headingFocused = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { selectedScreen = screen }
    }

    private var brand: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { brandMark; brandName.fixedSize(horizontal: true, vertical: false) }
            VStack(alignment: .leading, spacing: 16) { brandMark; brandName }
        }
        .accessibilityElement(children: .combine)
    }
    private var brandMark: some View {
        Image("CodecLogo").resizable().scaledToFit().frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder((theme.isLight ? Color.black : Color.white).opacity(0.1), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
    private var brandName: some View {
        Text("Codec").font(.largeTitle.weight(.black)).tracking(-1).foregroundStyle(theme.text)
    }
    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.muted)
    }
    private func field<Content: View>(icon: String, focused: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.body.weight(.medium)).foregroundStyle(theme.muted)
                .frame(width: fieldIconWidth).accessibilityHidden(true)
            content().font(.body).foregroundStyle(theme.text)
        }
        .padding(16)
        .frame(minHeight: 54)
        .background(theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(focused ? theme.accent : theme.border, lineWidth: 1) }
    }
    private func connect() {
        guard canConnect else { return }
        focusedField = nil
        Task { await app.connect(); app.syncPlayer(player) }
    }
}
