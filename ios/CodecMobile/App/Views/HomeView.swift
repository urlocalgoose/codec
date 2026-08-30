import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct HomeView: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player

    @State private var showSettings = false
    @State private var showThemePicker = false
    @State private var showAuxPass = false

    private let grid = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Faceplate badge, with the aux chip when a session is live.
                    HStack(alignment: .center, spacing: 12) {
                        Text("Codec")
                            .font(.system(size: 40, weight: .black))
                            .tracking(-1)
                            .foregroundStyle(theme.text)

                        Spacer(minLength: 0)

                        if !app.activeAuxCode.isEmpty {
                            Button {
                                showAuxPass = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                        .font(.system(size: 12, weight: .black))
                                    Text(app.activeAuxCode)
                                        .font(.system(size: 13, weight: .black, design: .monospaced))
                                        .kerning(2)
                                }
                                .foregroundStyle(theme.accent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(theme.accent.opacity(0.16))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)

                    if app.connection == .offline {
                        Label("Offline — playing downloads and cache", systemImage: "wifi.slash")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(theme.accentText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(theme.accent)
                            .clipShape(Capsule())
                            .padding(.horizontal, 20)
                    }

                    if !app.userPlaylists.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Playlists")
                                .padding(.horizontal, 20)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(app.userPlaylists) { playlist in
                                        NavigationLink {
                                            PlaylistDetailView(playlistID: playlist.id)
                                        } label: {
                                            PlaylistCard(
                                                playlist: playlist,
                                                cover: app.tracks(in: playlist).first
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Recently added")
                            .padding(.horizontal, 20)

                        LazyVGrid(columns: grid, spacing: 18) {
                            ForEach(app.recentItems) { item in
                                switch item {
                                case .album(let album, let cover):
                                    NavigationLink {
                                        TrackListView(title: album.name, tracks: app.tracks(inAlbum: album))
                                    } label: {
                                        AlbumTile(album: album, cover: cover)
                                    }
                                    .buttonStyle(.plain)
                                case .single(let track):
                                    Button {
                                        if player.currentTrack?.id == track.id {
                                            player.togglePlayback()
                                        } else {
                                            player.play(track, from: app.recentlyAdded)
                                        }
                                    } label: {
                                        RecentTile(track: track)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .background(theme.bg)
            .refreshable {
                await app.refresh()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showThemePicker = true
                    } label: {
                        Image(systemName: "paintpalette")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "server.rack")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                ServerSettingsView()
            }
            .sheet(isPresented: $showThemePicker) {
                ThemePickerView()
            }
            .sheet(isPresented: $showAuxPass) {
                AuxSessionSheet()
            }
        }
    }
}

private struct PlaylistCard: View {
    @Environment(\.codecTheme) private var theme

    let playlist: CodecPlaylist
    let cover: CodecTrack?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let art = playlist.artworkURL {
                    RemoteArtworkView(urlString: art, size: 128, cornerRadius: 10)
                } else {
                    ArtworkView(track: cover, size: 128, cornerRadius: 10)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            )

            Text(playlist.name)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(theme.text)
                .lineLimit(1)

            Text("\(playlist.trackIDs.count) songs")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.subtle)
        }
        .frame(width: 128, alignment: .leading)
    }
}

private struct AlbumTile: View {
    @Environment(\.codecTheme) private var theme

    let album: CodecAlbumSummary
    let cover: CodecTrack?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ArtworkView(track: cover, size: proxy.size.width, cornerRadius: 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.border, lineWidth: 1)
                    )
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 1) {
                Text(album.name)
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text("Album · \(album.artist)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
        }
    }
}

private struct RecentTile: View {
    @Environment(\.codecTheme) private var theme
    @Environment(PlayerController.self) private var player

    let track: CodecTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ArtworkView(track: track, size: proxy.size.width, cornerRadius: 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.border, lineWidth: 1)
                    )
            }
            .aspectRatio(1, contentMode: .fit)

            HStack(spacing: 5) {
                if player.currentTrack?.id == track.id {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundStyle(theme.accent)
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(player.currentTrack?.id == track.id ? theme.accent : theme.text)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct ServerSettingsView: View {
    @Environment(\.codecTheme) private var theme
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var showAuxSheet = false
    @State private var showJoinPrompt = false
    @State private var joinCode = ""

    var body: some View {
        @Bindable var app = app

        NavigationStack {
            Form {
                Section("Sync server") {
                    TextField("https://your-server or 192.168.1.20:8787", text: $app.serverURLString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField("Auth token (optional)", text: $app.token)
                }
                .listRowBackground(theme.panel)

                Section {
                    if app.activeAuxCode.isEmpty {
                        Button {
                            Task {
                                await app.startAux()
                                if !app.activeAuxCode.isEmpty {
                                    showAuxSheet = true
                                }
                            }
                        } label: {
                            Label(app.auxBusy ? "Starting Aux…" : "Start Aux", systemImage: "qrcode")
                        }
                        .disabled(app.auxBusy || !app.isConnected)
                    } else {
                        Button {
                            showAuxSheet = true
                        } label: {
                            HStack {
                                Label(
                                    app.activeAuxIsGuest ? "Joined Aux" : "Aux Live",
                                    systemImage: app.activeAuxIsGuest ? "person.2" : "dot.radiowaves.left.and.right"
                                )
                                Spacer()
                                Text(app.activeAuxCode)
                                    .font(.body.monospaced().weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button(app.activeAuxIsGuest ? "Leave Aux" : "End Aux", role: .destructive) {
                            Task {
                                await app.endAux()
                                app.syncPlayer(player)
                            }
                        }
                        .disabled(app.auxBusy)
                    }

                    Button {
                        showJoinPrompt = true
                    } label: {
                        Label("Join Aux", systemImage: "person.2")
                    }
                    .disabled(app.auxBusy || app.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Aux")
                } footer: {
                    Text("Guests can browse, stream, and control the shared queue. They can't change your library.")
                }
                .listRowBackground(theme.panel)

                Section {
                    Button("Reconnect") {
                        Task {
                            await app.connect()
                            app.syncPlayer(player)
                            dismiss()
                        }
                    }
                    Button("Disconnect", role: .destructive) {
                        app.disconnect()
                        app.syncPlayer(player)
                        dismiss()
                    }
                } footer: {
                    Text(app.errorMessage.isEmpty ? "Status: \(statusText)" : app.errorMessage)
                }
                .listRowBackground(theme.panel)
            }
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await app.refreshAuxState()
            }
            .sheet(isPresented: $showAuxSheet) {
                AuxSessionSheet()
            }
            .alert("Join Aux", isPresented: $showJoinPrompt) {
                TextField("Code", text: $joinCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Join") {
                    Task {
                        await app.joinAux(code: joinCode)
                        app.syncPlayer(player)
                        joinCode = ""
                        if !app.activeAuxCode.isEmpty {
                            showAuxSheet = true
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    joinCode = ""
                }
            } message: {
                Text("Enter the 4-character code from the host.")
            }
        }
    }

    private var statusText: String {
        switch app.connection {
        case .connected: return "connected"
        case .connecting: return "connecting…"
        case .offline: return "offline (cached library)"
        case .disconnected: return "not connected"
        }
    }
}

/// Native aux sheet: QR on a plain plate, the code, system buttons. Theme
/// arrives through tint and background only - no deck chrome on iOS.
struct AuxSessionSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(\.codecTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    // The lighter of the theme's bg/text is the QR paper so it stays scannable.
    private var qrInk: Color {
        theme.isLight ? theme.text : theme.bg
    }

    private var qrPaper: Color {
        theme.isLight ? theme.bg : theme.text
    }

    var body: some View {
        NavigationStack {
            Group {
                if let link = app.auxLink {
                    VStack(spacing: 28) {
                        Spacer(minLength: 0)

                        QRCodeImage(payload: link.absoluteString, foreground: qrInk, background: qrPaper)
                            .frame(width: 208, height: 208)
                            .padding(14)
                            .background(qrPaper, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                        VStack(spacing: 8) {
                            Text(app.activeAuxCode)
                                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                                .foregroundStyle(theme.text)
                            Text(app.activeAuxIsGuest ? "You're on the aux." : "Scan with a phone camera, or share the link.")
                                .font(.subheadline)
                                .foregroundStyle(theme.muted)
                                .multilineTextAlignment(.center)
                        }

                        Spacer(minLength: 0)

                        VStack(spacing: 10) {
                            ShareLink(item: link) {
                                Label("Share Link", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)

                            Button {
                                UIPasteboard.general.string = link.absoluteString
                            } label: {
                                Label("Copy Link", systemImage: "link")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            Button(role: .destructive) {
                                Task {
                                    await app.endAux()
                                    app.syncPlayer(player)
                                    dismiss()
                                }
                            } label: {
                                Text(app.activeAuxIsGuest ? "Leave Aux" : "End Aux")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(app.auxBusy)
                        }
                    }
                    .padding(20)
                } else {
                    ContentUnavailableView("No Aux", systemImage: "qrcode")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
            .navigationTitle(app.activeAuxIsGuest ? "Joined Aux" : "Aux Live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}


/// Codec's QR: round ink dots, softened finder eyes, and the grainy accent
/// logo tile sitting in the middle. Error correction runs at H so the
/// center knockout and dot rounding stay well inside the damage budget.
private struct QRCodeImage: View {
    @Environment(\.codecTheme) private var theme

    let payload: String
    let foreground: Color
    let background: Color

    var body: some View {
        if let grid = QRModuleGrid(payload: payload) {
            Canvas { context, size in
                draw(grid: grid, in: context, size: size)
            }
            .accessibilityLabel("Aux QR code")
        } else {
            Image(systemName: "qrcode")
                .font(.system(size: 120, weight: .regular))
        }
    }

    private func draw(grid: QRModuleGrid, in context: GraphicsContext, size: CGSize) {
        let n = grid.count
        let module = min(size.width, size.height) / CGFloat(n)
        let origin = CGPoint(
            x: (size.width - module * CGFloat(n)) / 2,
            y: (size.height - module * CGFloat(n)) / 2
        )

        func rect(_ x: Int, _ y: Int, span: Int = 1, inset: CGFloat = 0) -> CGRect {
            CGRect(
                x: origin.x + CGFloat(x) * module + inset,
                y: origin.y + CGFloat(y) * module + inset,
                width: module * CGFloat(span) - inset * 2,
                height: module * CGFloat(span) - inset * 2
            )
        }

        // Center knockout for the logo tile: ~1/5 of the symbol, odd so it
        // sits symmetric on the grid.
        var logoSpan = max(5, Int((Double(n) * 0.21).rounded()))
        if logoSpan % 2 != n % 2 {
            logoSpan += 1
        }
        let logoStart = (n - logoSpan) / 2
        let logoRange = logoStart..<(logoStart + logoSpan)

        func inFinder(_ x: Int, _ y: Int) -> Bool {
            (x < 7 && y < 7) || (x >= n - 7 && y < 7) || (x < 7 && y >= n - 7)
        }

        // Data modules as round dots.
        let dotInset = module * 0.11
        for y in 0..<n {
            for x in 0..<n {
                guard grid[x, y], !inFinder(x, y),
                      !(logoRange.contains(x) && logoRange.contains(y))
                else {
                    continue
                }
                context.fill(Circle().path(in: rect(x, y, inset: dotInset)), with: .color(foreground))
            }
        }

        // Finder eyes: rounded ring + pupil. The pupil takes the accent only
        // when it still reads as ink against the paper.
        let pupil = QRModuleGrid.contrastOK(theme.accent, against: background) ? theme.accent : foreground
        for (ex, ey) in [(0, 0), (n - 7, 0), (0, n - 7)] {
            context.fill(
                RoundedRectangle(cornerRadius: module * 2.2, style: .continuous)
                    .path(in: rect(ex, ey, span: 7)),
                with: .color(foreground)
            )
            context.fill(
                RoundedRectangle(cornerRadius: module * 1.6, style: .continuous)
                    .path(in: rect(ex + 1, ey + 1, span: 5)),
                with: .color(background)
            )
            context.fill(
                RoundedRectangle(cornerRadius: module * 1.1, style: .continuous)
                    .path(in: rect(ex + 2, ey + 2, span: 3)),
                with: .color(pupil)
            )
        }

        // The logo: accent tile with the logo's grain and the music note.
        let tile = rect(logoStart, logoStart, span: logoSpan, inset: module * 0.35)
        let tileShape = RoundedRectangle(cornerRadius: tile.width * 0.24, style: .continuous)
            .path(in: tile)
        context.fill(tileShape, with: .color(theme.accent))

        var grain = context
        grain.clip(to: tileShape)
        for index in 0..<70 {
            let gx = tile.minX + CGFloat((index * 47) % 101) / 101 * tile.width
            let gy = tile.minY + CGFloat((index * 83) % 107) / 107 * tile.height
            let diameter = CGFloat((index % 3) + 1) * tile.width * 0.014
            grain.fill(
                Circle().path(in: CGRect(x: gx, y: gy, width: diameter, height: diameter)),
                with: .color(theme.glint.opacity(index.isMultiple(of: 5) ? 0.42 : 0.6))
            )
        }

        let note = context.resolve(
            Text(Image(systemName: "music.note"))
                .font(.system(size: tile.width * 0.5, weight: .black))
                .foregroundStyle(theme.accentText)
        )
        context.draw(note, at: CGPoint(x: tile.midX, y: tile.midY))
    }
}

/// The raw QR module matrix, read back from CoreImage's generator at one
/// pixel per module.
private struct QRModuleGrid {
    let count: Int
    private let modules: [Bool]

    subscript(x: Int, y: Int) -> Bool {
        modules[y * count + x]
    }

    init?(payload: String) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "H"

        guard let output = filter.outputImage else {
            return nil
        }
        let width = Int(output.extent.width)
        let height = Int(output.extent.height)
        guard width > 0, width == height else {
            return nil
        }

        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let cgContext = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return nil
        }
        cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // CoreImage pads the symbol with a quiet-zone border, so trim to the
        // dark bounds - the renderer needs (0,0) to be the finder corner.
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] < 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let side = maxX - minX + 1
        guard maxX >= 0, side == maxY - minY + 1, side >= 21 else {
            return nil
        }

        var trimmed = [Bool](repeating: false, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                trimmed[y * side + x] = pixels[(minY + y) * width + (minX + x)] < 128
            }
        }

        // QR finders sit top-left, top-right, bottom-left. If the bitmap
        // came out upside down, the top-right corner has no finder.
        func finderAt(_ fx: Int, _ fy: Int) -> Bool {
            trimmed[fy * side + fx] && trimmed[(fy + 6) * side + fx] &&
                trimmed[(fy + 3) * side + (fx + 3)] && !trimmed[(fy + 1) * side + (fx + 1)]
        }
        if !finderAt(side - 7, 0), finderAt(side - 7, side - 7) {
            var flipped = [Bool](repeating: false, count: side * side)
            for y in 0..<side {
                for x in 0..<side {
                    flipped[y * side + x] = trimmed[(side - 1 - y) * side + x]
                }
            }
            trimmed = flipped
        }

        count = side
        modules = trimmed
    }

    /// Whether two colors differ enough in luminance for a scanner to keep
    /// treating the first as ink on the second.
    static func contrastOK(_ ink: Color, against paper: Color) -> Bool {
        func luminance(_ color: Color) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return abs(luminance(ink) - luminance(paper)) > 0.45
    }
}
