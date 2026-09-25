import SwiftUI
import UIKit
import XCTest
@testable import Codec

/// Optional integration run against the isolated loopback lab. The credential
/// fixture lives only in Codec Test's sandbox and is never included in artifacts.
@MainActor final class AuxNativeCaptureTests: XCTestCase {
    func testSignedOutOnboardingStartsWithHelpOnlyForFreshConnections() {
        XCTAssertEqual(ConnectView.initialScreen(server: "", token: "", connecting: false, message: ""), .welcome)
        XCTAssertEqual(ConnectView.initialScreen(server: " \n", token: " ", connecting: false, message: ""), .welcome)
        XCTAssertEqual(ConnectView.initialScreen(server: "https://example.invalid", token: "", connecting: false, message: ""), .connect)
        XCTAssertEqual(ConnectView.initialScreen(server: "", token: "saved-token", connecting: false, message: ""), .connect)
        XCTAssertEqual(ConnectView.initialScreen(server: "", token: "", connecting: true, message: ""), .connect)
        XCTAssertEqual(ConnectView.initialScreen(server: "", token: "", connecting: false, message: "Connection failed"), .connect)
    }

    func testCaptureSignedOutOnboardingBranches() async throws {
        #if LOCAL_TEST
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        guard FileManager.default.fileExists(atPath: caches.appendingPathComponent("codec-onboarding-capture").path) else {
            throw XCTSkip("Optional onboarding capture marker is absent")
        }
        let output = caches.appendingPathComponent("onboarding-native-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = AppModel()
        let player = PlayerController()
        let themes = ThemeStore()
        let savedServer = app.serverURLString
        let savedToken = app.token
        app.serverURLString = ""; app.token = ""
        defer { app.serverURLString = savedServer; app.token = savedToken }
        for screen in ConnectView.Screen.allCases {
            let content = ConnectView(initialScreen: screen).environment(app).environment(player)
                .environment(\.codecTheme, themes.theme).tint(themes.theme.accent)
            try await capture(content, to: output.appendingPathComponent("native-onboarding-\(screen.rawValue).png"))
            try await capture(content, to: output.appendingPathComponent("native-onboarding-\(screen.rawValue)-small.png"), size: CGSize(width: 320, height: 568))
            if screen == .explain {
                try await capture(content, to: output.appendingPathComponent("native-onboarding-explain-bottom.png"), scrollToBottom: true)
                try await capture(content, to: output.appendingPathComponent("native-onboarding-explain-small-bottom.png"), size: CGSize(width: 320, height: 568), scrollToBottom: true)
            }
        }
        let accessible = ConnectView(initialScreen: .welcome).environment(app).environment(player)
            .environment(\.codecTheme, themes.theme)
            .dynamicTypeSize(.accessibility3).tint(themes.theme.accent)
        try await capture(accessible, to: output.appendingPathComponent("native-onboarding-welcome-large-type.png"))
        try await capture(accessible, to: output.appendingPathComponent("native-onboarding-welcome-large-type-bottom.png"), scrollToBottom: true)
        #else
        throw XCTSkip("Capture is restricted to Codec Test")
        #endif
    }

    func testLocalHostFlowPreservesPersonalAuthorityAndCapturesActualViews() async throws {
        #if LOCAL_TEST
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let fixtureURL = caches.appendingPathComponent("codec-aux-capture.json")
        guard let fixtureData = try? Data(contentsOf: fixtureURL) else { throw XCTSkip("Optional local-server capture fixture is absent") }
        struct Fixture: Decodable { let server: URL; let token: String }
        let fixture = try JSONDecoder().decode(Fixture.self, from: fixtureData)
        guard fixture.server.scheme == "http", fixture.server.host == "127.0.0.1", fixture.server.port == 8792 else {
            XCTFail("Only isolated local server B may be used by this fixture"); return
        }
        let output = caches.appendingPathComponent("aux-native-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = AppModel()
        let player = PlayerController()
        let themeStore = ThemeStore()
        app.serverURLString = fixture.server.absoluteString
        app.token = fixture.token
        await app.connect()
        XCTAssertTrue(app.isConnected)
        let library = try XCTUnwrap(app.library)
        XCTAssertFalse(library.tracks.isEmpty)
        player.resolveTrack = { app.track(matching: $0) }
        app.syncPlayer(player)
        await player.reconcilePlayback()
        do {
            try await capture(AuxCreateView().environment(app).environment(player).environment(themeStore).environment(\.codecTheme, themeStore.theme).tint(themeStore.theme.accent), to: output.appendingPathComponent("native-start-aux.png"))
            let personalClient = try XCTUnwrap(app.client)
            await app.aux.create(personal: personalClient, player: player, mode: .listenTogether,
                                 tracks: library.tracks.prefix(100).map(\.fingerprint), allowSaves: false, allowContributions: true)
            XCTAssertEqual(app.aux.state?.role, "host", app.aux.issue)
            XCTAssertEqual(app.aux.state?.mode, .listenTogether)
            XCTAssertEqual(app.token, fixture.token)
            XCTAssertEqual(app.client?.baseURL, fixture.server)
            if app.aux.state?.current == nil, let first = library.tracks.first {
                await app.aux.command("append", fingerprint: first.fingerprint)
                await app.aux.command("resume")
            }
            try await capture(AuxSessionView().environment(app).environment(player).environment(themeStore).environment(\.codecTheme, themeStore.theme).tint(themeStore.theme.accent), to: output.appendingPathComponent("native-active-aux.png"))
            await app.aux.leaveOrEnd()
            XCTAssertFalse(app.aux.isActive)
            XCTAssertEqual(app.token, fixture.token)
            app.disconnect(); player.stopSync()
        } catch {
            await app.aux.leaveOrEnd(); app.disconnect(); player.stopSync()
            throw error
        }
        #else
        throw XCTSkip("Capture is restricted to the separate Codec Test identity")
        #endif
    }

    private func capture<Content: View>(_ content: Content, to url: URL, size: CGSize? = nil, scrollToBottom: Bool = false) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = size.map { CGRect(origin: .zero, size: $0) } ?? scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: content.preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        if let scroll = scrollView(in: window) {
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1, "Onboarding must not scroll horizontally")
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: scrollToBottom ? bottom : top), animated: false)
            window.layoutIfNeeded()
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: url, options: .atomic)
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
}
