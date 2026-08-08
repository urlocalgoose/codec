import AVFoundation
import CryptoKit
import SwiftUI

private let appTransportSecurityRequiresSecureConnectionCode = -1022

struct ContentView: View {
    @AppStorage("loud.serverURL") private var serverURL = "http://127.0.0.1:8787"
    @AppStorage("loud.deviceID") private var deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    @State private var status = "Device key not loaded."
    @State private var enrollmentText = ""
    @State private var isChecking = false
    @State private var library: SecureSyncLibrary?
    @State private var currentTrack: SecureSyncTrack?
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var didAutoLoad = false

    var body: some View {
        ZStack {
            LoudColor.bg.ignoresSafeArea()

            if let library {
                libraryScreen(library)
            } else {
                connectionScreen
            }
        }
        .tint(LoudColor.accent)
        .onAppear(perform: handleAppear)
    }

    private func sectionLabel(_ value: String) -> Text {
        Text(value.uppercased())
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(LoudColor.subtle)
    }

    private var connectionScreen: some View {
        ScrollView {
            VStack {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 26) {
                        HStack(spacing: 12) {
                            Image(systemName: "music.note")
                                .font(.system(size: 25, weight: .bold))
                                .foregroundStyle(LoudColor.accentText)
                                .frame(width: 52, height: 52)
                                .background(LoudColor.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                            Text("Loud")
                                .font(.system(size: 17, weight: .heavy))
                                .foregroundStyle(LoudColor.text)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            sectionLabel("iPhone")
                                .foregroundStyle(LoudColor.accent)

                            Text("Connect your Loud server.")
                                .font(.system(size: 38, weight: .heavy))
                                .lineSpacing(-2)
                                .foregroundStyle(LoudColor.text)

                            Text("Paste the URL printed by the sync server, then keep this device key for enrollment.")
                                .font(.system(size: 16, weight: .semibold))
                                .lineSpacing(2)
                                .foregroundStyle(LoudColor.muted)
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        sectionLabel("Sync server")
                        HStack(spacing: 10) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(LoudColor.subtle)
                                .frame(width: 22)

                            TextField("Server URL", text: $serverURL)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(LoudColor.text)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 48)
                        .background(LoudColor.bg.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(LoudColor.line, lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.22), radius: 0, x: 0, y: 2)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        sectionLabel("Device")
                        Text(deviceID)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LoudColor.muted)
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(LoudColor.panel2)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    HStack(spacing: 0) {
                        Button(action: prepareDeviceKeyPreview) {
                            VStack(spacing: 5) {
                                Image(systemName: "key")
                                Text("Key")
                            }
                            .font(.system(size: 13, weight: .heavy))
                        }
                        .buttonStyle(DeckButtonStyle(leftRadius: true, rightRadius: false))

                        Rectangle()
                            .fill(LoudColor.line)
                            .frame(width: 1)

                        Button {
                            Task {
                                await checkServerAndPrepareDevice()
                            }
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: isChecking ? "arrow.triangle.2.circlepath" : "antenna.radiowaves.left.and.right")
                                Text(isChecking ? "Loading" : "Check")
                            }
                            .font(.system(size: 13, weight: .heavy))
                        }
                        .buttonStyle(DeckButtonStyle(primary: true, leftRadius: false, rightRadius: true))
                        .disabled(isChecking)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    Text(status)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(status.hasPrefix("Error") ? LoudColor.danger : LoudColor.subtle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !enrollmentText.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            sectionLabel("Enrollment payload")
                            Text(enrollmentText)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(LoudColor.muted)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(LoudColor.panel)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(24)
                .background(LoudColor.panel.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(LoudColor.line, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.38), radius: 48, x: 0, y: 24)
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: UIScreen.main.bounds.height - 40, alignment: .center)
        }
    }

    private func libraryScreen(_ library: SecureSyncLibrary) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Loud")
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(LoudColor.text)

                    Text("\(library.tracks.count) tracks")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LoudColor.subtle)
                }

                Spacer()

                Button {
                    Task {
                        await checkServerAndPrepareDevice()
                    }
                } label: {
                    Image(systemName: isChecking ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 18, weight: .heavy))
                }
                .buttonStyle(DeckButtonStyle(leftRadius: true, rightRadius: true))
                .frame(width: 52)
                .disabled(isChecking)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Rectangle()
                .fill(LoudColor.line)
                .frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(library.tracks) { track in
                        trackRow(track)
                    }
                }
                .padding(.vertical, 6)
            }

            if let currentTrack {
                playerBar(currentTrack)
            }
        }
    }

    private func trackRow(_ track: SecureSyncTrack) -> some View {
        Button {
            play(track)
        } label: {
            HStack(spacing: 12) {
                artworkView(track)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(LoudColor.text)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LoudColor.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(formatDuration(track.durationSeconds))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LoudColor.subtle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(currentTrack?.id == track.id ? LoudColor.panel2 : Color.clear)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func artworkView(_ track: SecureSyncTrack) -> some View {
        if let artworkURL = track.artworkURL {
            AsyncImage(url: artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    artworkPlaceholder
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            artworkPlaceholder
                .frame(width: 44, height: 44)
        }
    }

    private var artworkPlaceholder: some View {
        ZStack {
            LoudColor.panel2
            Image(systemName: "music.note")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(LoudColor.subtle)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func playerBar(_ track: SecureSyncTrack) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(LoudColor.text)
                    .lineLimit(1)

                Text(track.artist)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LoudColor.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .heavy))
            }
            .buttonStyle(DeckButtonStyle(primary: true, leftRadius: true, rightRadius: true))
            .frame(width: 64)
        }
        .padding(14)
        .background(LoudColor.panel)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LoudColor.line)
                .frame(height: 1)
        }
    }

    private func prepareDeviceKeyPreview() {
        do {
            let key = try DeviceKeyStore.loadOrCreatePrivateKey()
            let signer = SecureSyncSigner(deviceID: deviceID, privateKey: key)
            let client = SecureSyncClient(baseURL: try normalizedServerURL(), signer: signer)
            enrollmentText = try prettyPrintedJSON(client.enrollmentRequest(name: UIDevice.current.name, platform: "ios"))
            status = "Device key ready. Server not checked yet."
        } catch {
            status = statusMessage(for: error)
        }
    }

    private func handleAppear() {
        prepareDeviceKeyPreview()
        guard !didAutoLoad else {
            return
        }
        didAutoLoad = true
        Task {
            await checkServerAndPrepareDevice()
        }
    }

    private func checkServerAndPrepareDevice() async {
        isChecking = true
        defer { isChecking = false }

        do {
            let key = try DeviceKeyStore.loadOrCreatePrivateKey()
            let signer = SecureSyncSigner(deviceID: deviceID, privateKey: key)
            let client = SecureSyncClient(baseURL: try normalizedServerURL(), signer: signer)
            let health = try await client.health()
            let remoteLibrary = try await client.library()
            enrollmentText = try prettyPrintedJSON(client.enrollmentRequest(name: UIDevice.current.name, platform: "ios"))
            library = remoteLibrary
            if let playbackSchema = health.playbackSchema {
                status = "Loaded \(remoteLibrary.tracks.count) tracks from \(health.schema) with \(playbackSchema)."
            } else {
                status = "Loaded \(remoteLibrary.tracks.count) tracks from \(health.schema)."
            }
        } catch {
            status = statusMessage(for: error)
        }
    }

    private func normalizedServerURL() throws -> URL {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw ContentViewError.invalidServerURL
        }
        return url
    }

    private func play(_ track: SecureSyncTrack) {
        guard let audioURL = track.audioURL else {
            status = "Error: This track has no audio file on the sync server."
            return
        }

        configureAudioSession()
        currentTrack = track
        player?.pause()
        player = AVPlayer(url: audioURL)
        player?.play()
        isPlaying = true
    }

    private func togglePlayback() {
        guard let player else {
            if let currentTrack {
                play(currentTrack)
            } else if let firstTrack = library?.tracks.first {
                play(firstTrack)
            }
            return
        }

        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            status = statusMessage(for: error)
        }
    }

    private func formatDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else {
            return "--:--"
        }
        let totalSeconds = Int(seconds.rounded())
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    private func prettyPrintedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: try encoder.encode(value), encoding: .utf8) ?? ""
    }

    private func statusMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == appTransportSecurityRequiresSecureConnectionCode {
            return "Error: iOS blocked this HTTP server. Rebuild the local app or use an HTTPS sync URL."
        }
        return "Error: \(error.localizedDescription)"
    }
}

enum ContentViewError: LocalizedError {
    case invalidServerURL

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Enter a server URL like http://192.168.1.20:8787."
        }
    }
}

#Preview {
    ContentView()
}
