// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A transcript in the sidebar: its name, flairs, and where its work stands.
struct EntryRow: View {
    let item: LibraryItem
    let stage: AppModel.Stage?
    var folderName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: Spacing.icon) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.flairs.isEmpty {
                    Spacer(minLength: 0)
                    FlairIcons(flairs: item.flairs, maxCount: 4)
                        .accessibilityHidden(stage == nil && item.state == .finished)
                }
            }
            status
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .waiting:
            Text(joinedStatus(stage.map(\.line) ?? String(localized: "Waiting")))
        case .running:
            Text(joinedStatus(stage.map(\.line) ?? AppModel.Stage.decoding.title))
        case .finished:
            // Busy while finished only when its repeats are transcribed again.
            if let stage {
                Text(joinedStatus(stage.line))
            } else {
                Text(finishedSummary)
            }
        case .stopped:
            Text(joinedStatus(String(localized: "Stopped before the end")))
        case .failed:
            Notice(joinedStatus(String(localized: "Failed")), .failure)
        }
    }

    private func joinedStatus(_ stateText: String) -> String {
        guard let folderName else { return stateText }
        return "\(folderName) · \(stateText)"
    }

    private var finishedSummary: String {
        var parts: [String] = []
        if let folderName { parts.append(folderName) }
        if !item.flairs.isEmpty {
            parts.append(contentsOf: item.flairs.map(\.displayTitle))
        } else if folderName == nil {
            parts.append(String(localized: "Ready to review"))
        }
        return parts.joined(separator: " · ")
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
