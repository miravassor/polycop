// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import Testing

@testable import Polycop

/// Shows each scene in a window of the app for `Tools/scenes.sh` to capture.
/// It runs only when that script asks, since it puts windows on the screen:
/// the script names a folder, where each window is announced and answered.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SCENE_DIR"] != nil))
struct SceneShots {
    /// The sizes worth checking: the smallest the window allows, with the
    /// library hidden as a reader with so little room hides it, and one that
    /// fills a 13 inch screen under its menu bar. Not full screen itself,
    /// which a window behind the others cannot enter.
    static let sizes: [(name: String, size: NSSize?)] = [
        ("smallest", nil),
        ("wide", NSSize(width: 1440, height: 900)),
    ]

    private static let clip = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/formats/clip.m4a")

    @Test func shows() async throws {
        let folder = try #require(ProcessInfo.processInfo.environment["SCENE_DIR"])
        let wanted = (ProcessInfo.processInfo.environment["SCENES"] ?? "")
            .split(separator: " ").map(String.init)
        let unknown = Set(wanted).subtracting(AppScene.all.map(\.name)).sorted()
        try #require(unknown.isEmpty, "No scene is named \(unknown.joined(separator: ", "))")
        for scene in AppScene.all where wanted.isEmpty || wanted.contains(scene.name) {
            for size in Self.sizes {
                for isLight in [true, false] {
                    let name = "\(scene.name)-\(size.name)-\(isLight ? "light" : "dark")"
                    try await show(scene, as: name, size: size.size, isLight: isLight, in: folder)
                }
            }
        }
    }

    /// Shows a scene on a library of its own, at `size` or the smallest the
    /// window allows, until the script has captured it.
    private func show(
        _ scene: AppScene, as name: String, size: NSSize?, isLight: Bool, in folder: String
    ) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ModelCatalog.recommended.id
        let ids = try addWaitingRecordings(
            [("Example recording 1.m4a", model), ("Example recording 2.m4a", model)],
            copying: Self.clip, to: root)
        let defaults = MemoryDefaults()
        defaults.set(size != nil, forKey: WindowLayout.showsLibraryKey)
        let engines = Opener(ScriptedEngine())
        let app = AppModel(
            history: root.appending(path: "History"),
            glossaries: root.appending(path: "Glossaries"),
            models: root.appending(path: "Models"), playbackCopies: root.appending(path: "Copies"),
            engines: engines.engines, defaults: defaults)
        scene.arrange(AppScene.Stage(model: app, engines: engines, first: ids[0], second: ids[1]))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size ?? NSSize(width: 1000, height: 700)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // As `PolycopApp` asks of its window: the tools with no title beside them.
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(
            rootView: ContentView(model: app).defaultAppStorage(defaults))
        window.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
        do {
            try await capture(scene, in: window, as: name, size: size, folder: folder)
        } catch {
            await app.shutDown()
            throw error
        }
        await app.shutDown()
    }

    private func capture(
        _ scene: AppScene, in window: NSWindow, as name: String, size: NSSize?, folder: String
    ) async throws {
        window.makeKeyAndOrderFront(nil)
        // The page settles over a few turns, the sidebar, the scroll bar and
        // the player, and says nowhere that it has: nothing to wait for but time.
        try await Task.sleep(for: .seconds(2))
        // The smallest size is the page's own, known once it is laid out.
        window.setContentSize(size ?? window.contentMinSize)
        try await scene.act(window)
        try await Task.sleep(for: .milliseconds(500))
        // A screen too small for the size asked would give a picture of another.
        let shown = try #require(window.contentView).frame.size
        if let size { #expect(shown == size, "\(name) is \(shown), not the \(size) asked") }

        // The script captures the window it is told of, then says so.
        let announced = "\(folder)/\(name).window"
        try "\(window.windowNumber)".write(toFile: announced, atomically: true, encoding: .utf8)
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: "\(folder)/\(name).done") {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(
            FileManager.default.fileExists(atPath: "\(folder)/\(name).png"),
            "\(name) was not captured")
    }
}
