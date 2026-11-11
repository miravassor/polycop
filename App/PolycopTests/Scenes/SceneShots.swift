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
    /// The sizes worth checking: the smallest window, where the library is
    /// hidden as a reader with so little room hides it, and a full screen.
    static let sizes: [(name: String, size: NSSize)] = [
        ("smallest", NSSize(width: 860, height: 600)),
        ("full", NSSize(width: 1470, height: 956)),
    ]

    @Test func shows() async throws {
        let folder = try #require(ProcessInfo.processInfo.environment["SCENE_DIR"])
        let wanted = (ProcessInfo.processInfo.environment["SCENES"] ?? "")
            .split(separator: " ").map(String.init)
        let scenes = Scene.all.filter { wanted.isEmpty || wanted.contains($0.name) }
        #expect(!scenes.isEmpty, "No scene is named \(wanted)")
        for scene in scenes {
            for size in Self.sizes {
                for isLight in [true, false] {
                    let name = "\(scene.name)-\(size.name)-\(isLight ? "light" : "dark")"
                    try await show(scene, as: name, size: size.size, isLight: isLight, in: folder)
                }
            }
        }
    }

    private func show(
        _ scene: Scene, as name: String, size: NSSize, isLight: Bool, in folder: String
    ) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appending(path: "History")
        var ids: [Entry.ID] = []
        for (index, title) in ["Example recording 1.m4a", "Example recording 2.m4a"].enumerated() {
            let recording = root.appending(path: title)
            try FileManager.default.copyItem(
                at: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .appending(path: "Fixtures/formats/clip.m4a"), to: recording)
            var entry = Entry(
                recording: recording, modelFile: ModelCatalog.recommended.id, glossary: nil,
                skipsSilence: false, subtitles: false)
            entry.added = Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index))
            try HistoryStore.write(entry, in: history)
            ids.append(entry.id)
        }
        let defaults = MemoryDefaults()
        defaults.set(size.width > 1000, forKey: WindowLayout.showsLibraryKey)
        let model = AppModel(
            history: history, glossaries: root.appending(path: "Glossaries"),
            models: root.appending(path: "Models"), playbackCopies: root.appending(path: "Copies"),
            defaults: defaults)
        scene.arrange(Scene.Stage(model: model, first: ids[0], second: ids[1]))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: ContentView(model: model).defaultAppStorage(defaults))
        window.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        // The page settles over a few turns: the sidebar, the scroll bar, the player.
        try await Task.sleep(for: .seconds(2))
        try await scene.act(window)
        try await Task.sleep(for: .milliseconds(500))

        // The script captures the window it is told of, then says so.
        let announced = "\(folder)/\(name).window"
        try "\(window.windowNumber)".write(toFile: announced, atomically: true, encoding: .utf8)
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: "\(folder)/\(name).done") {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(
            FileManager.default.fileExists(atPath: "\(folder)/\(name).png"),
            "\(name) was not captured")
        window.close()
        await model.shutDown()
    }
}
