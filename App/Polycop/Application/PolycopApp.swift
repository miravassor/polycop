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
        // in those folders; two copies otherwise work side by side.
        if !PolycopApp.isAnotherCopyRunning {
            ModelStore.sweep()
            Player.sweep()
        }
        _model = State(initialValue: AppModel())
    }

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
            // from anywhere, with the shortcuts a Mac user expects. The export
            // commands live beside the transcript itself, where the state that
            // decides between updating and choosing a place is.
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

        // The one preference that is not part of a recording's settings: it
        // applies to the Mac while any work runs, and changes take effect at
        // once rather than with the recordings added next.
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Late enough that the window is on screen before any question.
        Task {
            try? await Task.sleep(for: .seconds(5))
            UpdatePrompt.checkAutomaticallyIfDue()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Typing not handed over yet reaches the model before it is saved.
        TypingBuffer.flush()
        guard let model else { return .terminateNow }
        model.rememberPlace(in: model.pane)
        guard !model.isShuttingDown else { return .terminateLater }
        if model.hasWork {
            let alert = NSAlert()
            alert.messageText = String(localized: "Stop the transcriptions in progress?")
            alert.informativeText = String(
                localized:
                    "Quitting stops the recording being transcribed and those waiting. They stay in the list, to transcribe again."
            )
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Quit Anyway"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        Task {
            await model.shutDown()
            if !model.retrySavingHistory() {
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
/// and a resume once typing stops.
private struct PlaybackSettings: View {
    @AppStorage(Player.resumeRewindKey) private var resumeRewind = Player.defaultResumeRewind
    @AppStorage(Player.pausesWhileTypingKey) private var pausesWhileTyping = true
    @AppStorage(Player.resumeAfterTypingKey) private var resumeAfterTyping =
        Player.defaultResumeAfterTyping

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
    }
}
