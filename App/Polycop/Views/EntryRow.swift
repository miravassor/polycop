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
            Text("Waiting")
        case .running:
            switch stage {
            case .transcribing(let progress): Text("Transcribing · \(percent(progress))")
            case .repairing(let progress): Text("Repeats · \(percent(progress))")
            case .paused(let progress): Text("Paused · \(percent(progress))")
            case .stopping: Text("Stopping")
            default: Text("Preparing")
            }
        case .finished:
            // Busy while finished only when its repeats are transcribed again.
            switch stage {
            case .repairing(let progress): Text("Repeats · \(percent(progress))")
            case nil: Text("Ready to review")
            default: Text("Preparing")
            }
        case .stopped:
            Text("Stopped before the end")
        case .failed:
            Label("Failed", systemImage: "exclamationmark.circle")
        }
    }
}

func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
}
