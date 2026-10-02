// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

@main
struct PolycopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    init() {
        // Leftovers of a run that did not quit normally, removed once at launch
        // and before the model reads the folders. Not in the model itself: tests
        // and previews create models while files are being written. Skipped
        // while another copy runs, since its downloads and playback copies are
        // in those folders, such as the test host's. A test run and a second
        // copy leave them to the copy that has the library.
        if !Self.isHostingTests, !Self.isSecondCopy, !Self.isAnotherCopyRunning {
            ModelStore.sweep()
            Player.sweep()
        }
        _model = State(
            initialValue: AppModel(
                history: Self.library, glossaries: Self.glossaries,
                playbackCopies: Self.playbackCopies))
    }

    /// The transcript on screen, when it has text to export and is not being
    /// transcribed.
    private var openTranscript: Entry? {
        guard case .entry(let id) = model.pane, model.busyEntry != id,
            let entry = model.entry(id), !entry.paragraphs.isEmpty
        else { return nil }
        return entry
    }

    /// Updates the export as Save would a document, or asks where to put one
    /// when there is none to update.
    private func exportOpenTranscript(choosingPlace: Bool) {
        TypingBuffer.flush()
        guard let entry = openTranscript else { return }
        switch model.exportState(of: entry) {
        case .outOfDate where !choosingPlace: model.updateExport(entry.id)
        case .current where !choosingPlace: break
        default: EntryExportCard.exportAs(entry, with: model)
        }
    }

    static var isHostingTests: Bool { TestHost.isRunning }

    /// Whether another copy of the app has the user's library. Each copy
    /// writes what it read at launch, so a second one would write over the
    /// first one's changes: it opens nothing and hands over instead.
    static let isSecondCopy = !isHostingTests && (!HistoryStore.claim() || isOlderCopyRunning)

    /// Whether a copy of an earlier build is open. Builds before the library
    /// lock, such as 0.3.2, open the library without taking it, so the lock
    /// alone does not see them.
    private static var isOlderCopyRunning: Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let current = NSRunningApplication.current.processIdentifier
        let own = build(of: Bundle.main)
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains { other in
                other.processIdentifier != current
                    && (other.bundleURL.flatMap(Bundle.init(url:)).map(build(of:)) ?? own) < own
            }
    }

    private static func build(of bundle: Bundle) -> Int {
        (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) ?? 0
    }

    /// The library the window opens. A test run and a second copy get an empty
    /// one of their own, since opening the user's marks what was waiting or
    /// running as stopped, and glossaries and playback copies of their own
    /// beside it. Models are only read, so they stay the user's.
    static let library = ownFolder?.appending(path: "History") ?? HistoryStore.directory
    static let glossaries = ownFolder?.appending(path: "Glossaries") ?? GlossaryStore.directory
    static let playbackCopies = ownFolder?.appending(path: "Replay") ?? Player.copies

    private static let ownFolder =
        isHostingTests || isSecondCopy
        ? URL.temporaryDirectory.appending(path: "Polycop \(UUID().uuidString)") : nil

    private static var isAnotherCopyRunning: Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let current = NSRunningApplication.current.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains { $0.processIdentifier != current }
    }

    var body: some Scene {
        // One transcript window, not a group: a second one would load its own copy of the
        // weights, which the memory budget for small machines does not allow.
        Window("Polycop", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 980, height: 660)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdatePrompt.checkForUpdates() }
            }
            // The File menu of an app without documents: what the window can do
            // from anywhere, with the shortcuts a Mac user expects.
            CommandGroup(replacing: .newItem) {
                Button("New Transcription") { model.pane = .new }
                    .keyboardShortcut("n")
                Button("Add Recordings…") { model.chooseRecordings() }
                    .keyboardShortcut("o")
                Button("Import Transcript and Audio…") { model.chooseTranscriptImport() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.stage.isBusy)
                Button("Start Transcription") {
                    if case .entry(let id) = model.pane, model.isScheduled(id) {
                        model.continueQueue()
                    } else {
                        model.start()
                    }
                }
                .keyboardShortcut("r")
                .disabled(!model.canStart)
                Divider()
                Button("New Folder…") { model.addFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.foldersAreDamaged)
                Button("Manage Glossaries…") { model.manageGlossaries() }
                    .keyboardShortcut("g", modifiers: [.command, .option])
                Divider()
                // Enabled whatever the export's state, which typing not yet
                // handed to the model can have changed by the time the key
                // arrives: the action reads it once the typing is in.
                Button("Export Text") { exportOpenTranscript(choosingPlace: false) }
                    .keyboardShortcut("s")
                    .disabled(openTranscript == nil)
                Button("Export Text As…") { exportOpenTranscript(choosingPlace: true) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(openTranscript == nil)
            }
            CommandMenu("Playback") {
                // Only the paragraph being edited knows where its words are.
                Button("Play From Cursor") {
                    let action = #selector(WordTextView.playFromCursor(_:))
                    if !NSApp.sendAction(action, to: nil, from: nil) { NSSound.beep() }
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
            }
            CommandGroup(after: .help) {
                Button("Keyboard Shortcuts…") { openWindow(id: "shortcuts") }
                    .keyboardShortcut("/", modifiers: [.command, .option])
            }
        }

        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutHelpView()
        }
        .windowResizability(.contentSize)

        // Preferences that are not part of a recording's settings: they apply
        // at once rather than with the recordings added next.
        Settings {
            Form {
                Section("Polycop") {
                    LabeledContent("Version") {
                        Text(
                            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                                as? String ?? "Unknown"
                        )
                        .textSelection(.enabled)
                    }
                    LabeledContent("Build") {
                        Text(
                            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                                ?? "Unknown"
                        )
                        .textSelection(.enabled)
                    }
                }
                Section("Playback") {
                    PlaybackSettings()
                }
                Section("Updates") {
                    UpdateSettings()
                }
                Section("Keyboard") {
                    Button("Keyboard Shortcuts…") { openWindow(id: "shortcuts") }
                }
                Toggle(isOn: $model.keepAwake) {
                    Text("Keep the Mac awake while working")
                    Text(
                        "Prevents idle sleep while a transcription runs. Closing the lid still puts your Mac to sleep."
                    )
                }
            }
            .formStyle(.grouped)
            .frame(width: 420)
        }
    }
}

/// Releases the engine before the process exits. A loaded context alive at
/// termination aborts inside the framework's static Metal teardown, which is a
/// crash a user would see on quitting after a transcription.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if PolycopApp.isSecondCopy { handOver() }
    }

    /// Brings the copy that has the library forward and quits, as the system
    /// does when an app already open is launched again. Nothing is said: the
    /// open copy coming forward is the answer.
    private func handOver() {
        let current = NSRunningApplication.current
        let open = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        )
        .first { $0.processIdentifier != current.processIdentifier }
        if let open {
            // Cooperative activation: this copy gives way, then asks for the
            // open one to come forward.
            NSApp.yieldActivation(to: open)
            open.activate(from: current, options: [])
        }
        NSApp.terminate(nil)
    }

    /// Whether the check after launch has run, before which coming forward
    /// checks nothing.
    private var hasCheckedAtLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Late enough that the window is on screen before any question.
        Task {
            try? await Task.sleep(for: .seconds(5))
            UpdatePrompt.checkAutomaticallyIfDue(atLaunch: true)
            hasCheckedAtLaunch = true
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard hasCheckedAtLaunch else { return }
        UpdatePrompt.checkAutomaticallyIfDue(atLaunch: false)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Typing not handed over yet reaches the model before it is saved.
        TypingBuffer.flush()
        guard let model else { return .terminateNow }
        model.rememberPlace(in: model.pane)
        guard !model.isShuttingDown else { return .terminateLater }
        // Recordings that only wait lose nothing by quitting: they stay queued.
        if model.running != nil || model.stage.isBusy {
            let alert = NSAlert()
            alert.messageText = String(localized: "Stop the work in progress?")
            alert.informativeText =
                model.downloadingModel != nil
                ? String(
                    localized:
                        "Quitting stops the model download, which continues where it stopped at the next Download. Recordings waiting stay in the queue for the next Start."
                )
                : String(
                    localized:
                        "Quitting stops the recording being transcribed, which stays in the list to transcribe again. Recordings waiting stay in the queue for the next Start."
                )
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Quit Anyway"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        Task {
            await model.shutDown()
            if await !model.retrySavingHistory() {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Some changes could not be saved")
                alert.informativeText = String(
                    localized:
                        "Keep the app open to retry saving your history. Quitting now loses the changes that exist only in memory."
                )
                alert.addButton(withTitle: String(localized: "Keep App Open"))
                alert.addButton(withTitle: String(localized: "Quit Without Saving"))
                guard alert.runModal() == .alertSecondButtonReturn else {
                    model.cancelTermination()
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The automatic update check, off until the user allows it.
private struct UpdateSettings: View {
    @AppStorage(UpdatePrompt.automaticKey) private var checksAutomatically = false

    var body: some View {
        Toggle(isOn: $checksAutomatically) {
            Text("Check for updates automatically")
            Text("Asks GitHub once a day whether a newer version is out.")
        }
        Button("Check Now") { UpdatePrompt.checkForUpdates() }
    }
}

/// How playback helps correcting: a step back on resume, a pause while typing,
/// a resume once typing stops, and a cursor that can follow the word heard.
private struct PlaybackSettings: View {
    @AppStorage(Player.resumeRewindKey) private var resumeRewind = Player.defaultResumeRewind
    @AppStorage(Player.pausesWhileTypingKey) private var pausesWhileTyping = true
    @AppStorage(Player.resumeAfterTypingKey) private var resumeAfterTyping =
        Player.defaultResumeAfterTyping
    @AppStorage(Player.cursorFollowsPlaybackKey) private var cursorFollowsPlayback = false

    var body: some View {
        Picker("Step back on resume", selection: $resumeRewind) {
            Text("None").tag(0.0)
            ForEach([0.5, 1, 1.5, 2, 3, 5], id: \.self) { seconds in
                Text("\(seconds.formatted()) s").tag(seconds)
            }
        }
        Toggle(isOn: $pausesWhileTyping) {
            Text("Pause while typing a correction")
            Text("Playback stops at the first key pressed in the transcript.")
        }
        Picker("Resume after typing stops", selection: $resumeAfterTyping) {
            Text("Never").tag(0.0)
            ForEach([1, 1.5, 2, 3, 5], id: \.self) { seconds in
                Text("\(seconds.formatted()) s").tag(seconds)
            }
        }
        .disabled(!pausesWhileTyping)
        Toggle(isOn: $cursorFollowsPlayback) {
            Text("Move the text cursor with playback")
            Text(
                "After a correction, the cursor follows the word heard, to type the next one there."
            )
        }
    }
}
