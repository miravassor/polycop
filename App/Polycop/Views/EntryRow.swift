// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A transcript in the sidebar: its name and where its work stands.
struct EntryRow: View {
    let entry: Entry
    let stage: AppModel.Stage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            status
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch entry.state {
        case .waiting:
            Text(stage.map(\.line) ?? String(localized: "Waiting"))
        case .running:
            Text(stage.map(\.line) ?? AppModel.Stage.decoding.title)
        case .finished:
            // Busy while finished only when its repeats are transcribed again.
            Text(stage.map(\.line) ?? String(localized: "Ready to review"))
        case .stopped:
            Text("Stopped before the end")
        case .failed:
            Label("Failed", systemImage: "exclamationmark.circle")
        }
    }
}

/// The words for the work under way, the same in the library and on the
/// transcript's page, so a state never has two names.
extension AppModel.Stage {
    var title: String {
        switch self {
        case .downloading: String(localized: "Downloading the model")
        case .transcribing: String(localized: "Transcribing")
        case .repairing: String(localized: "Transcribing the repeats")
        case .paused: String(localized: "Paused")
        case .stopping: String(localized: "Stopping")
        case .waiting, .loading, .decoding: String(localized: "Preparing")
        }
    }

    /// The title with how far it is, for a line of its own.
    var line: String {
        guard let fraction else { return title }
        return "\(title) · \(percent(fraction))"
    }
}

func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
}
