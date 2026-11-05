// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

private func name(of record: UnavailableRecord) -> String {
    record.name ?? String(localized: "Untitled Transcript")
}

private func name(ofUnidentified files: [URL]) -> String {
    files.count == 1
        ? String(localized: "1 Unreadable File")
        : String(localized: "\(files.count) Unreadable Files")
}

/// A record that cannot be read, in the library: its name with a warning, and
/// nothing that would change it.
struct UnavailableRecordRow: View {
    let title: String
    let status: LocalizedStringKey
    let files: [URL]

    init(_ record: UnavailableRecord) {
        title = name(of: record)
        status = record.needsNewerVersion ? "Needs a newer version" : "Could not be read"
        files = [record.file]
    }

    init(unidentified files: [URL]) {
        title = name(ofUnidentified: files)
        status = "Could not be read"
        self.files = files
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // A stack, not a `Notice`: a sidebar gives a label's icon a column
            // as wide as a section's symbol, far from a name it should sit beside.
            HStack(alignment: .firstTextBaseline, spacing: Spacing.icon) {
                Image(systemName: NoticeState.warning.symbol)
                    .imageScale(.small)
                    .foregroundStyle(NoticeState.warning.tint)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files) }
        }
    }
}

/// What cannot be read in one place of the library, first in its section, where
/// it is seen.
struct UnavailableRows: View {
    let model: AppModel
    /// Nil for what is in no folder, where the unidentified files go too.
    let folder: UUID?

    var body: some View {
        if folder == nil, !model.unidentifiedFiles.isEmpty {
            UnavailableRecordRow(unidentified: model.unidentifiedFiles)
                .tag(AppModel.Pane.unidentifiedFiles)
        }
        ForEach(model.unavailable(in: folder)) { record in
            UnavailableRecordRow(record).tag(AppModel.Pane.unavailable(record.id))
        }
    }
}

/// The page of a record that cannot be read: what happened, and the one thing to
/// do about it.
struct UnavailableRecordPage: View {
    let title: String
    let description: LocalizedStringKey
    let needsNewerVersion: Bool
    let files: [URL]

    /// The page for what the window shows, if it is one of these.
    init?(model: AppModel) {
        switch model.pane {
        case .unavailable(let file):
            guard let record = model.unavailable.first(where: { $0.id == file }) else { return nil }
            self.init(record)
        case .unidentifiedFiles:
            self.init(unidentified: model.unidentifiedFiles)
        case .new, .entry:
            return nil
        }
    }

    init(_ record: UnavailableRecord) {
        title = name(of: record)
        needsNewerVersion = record.needsNewerVersion
        description =
            record.needsNewerVersion
            ? "This transcript was saved by a newer version. It has been left untouched: update Polycop to open it."
            : "This file is damaged. It has been left untouched, and can be replaced from a backup."
        files = [record.file]
    }

    init(unidentified files: [URL]) {
        title = name(ofUnidentified: files)
        needsNewerVersion = false
        description =
            "Nothing in these files says which transcripts they hold. They have been left untouched, and can be replaced from a backup."
        self.files = files
    }

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                Image(systemName: NoticeState.warning.symbol)
                    .foregroundStyle(NoticeState.warning.tint)
            }
        } description: {
            Text(description)
        } actions: {
            if needsNewerVersion {
                ActionButton(title: "Check for Updates…", systemImage: "arrow.down.circle") {
                    UpdatePrompt.checkForUpdates()
                }
            } else {
                ActionButton(title: "Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting(files)
                }
            }
        }
        .navigationTitle(title)
    }
}

#Preview("Rows") {
    List {
        UnavailableRecordRow(unidentified: [URL(filePath: "/tmp/a.json")])
        UnavailableRecordRow(
            UnavailableRecord(
                file: URL(filePath: "/tmp/made-up.json"), reason: "", needsNewerVersion: true,
                name: "Made up class.m4a"))
    }
    .listStyle(.sidebar)
}

#Preview("Newer") {
    UnavailableRecordPage(
        UnavailableRecord(
            file: URL(filePath: "/tmp/made-up.json"), reason: "", needsNewerVersion: true,
            name: "Made up class.m4a"))
}

#Preview("Unidentified") {
    UnavailableRecordPage(
        unidentified: [URL(filePath: "/tmp/a.json"), URL(filePath: "/tmp/b.json")])
}
