// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

extension View {
    /// What went wrong with the library, above this page's content. It goes on
    /// the content rather than on the page, whose inspector would start below it.
    /// The content takes the whole height, or the warnings would stay against
    /// a page centred in the window rather than at the top.
    func libraryWarnings(_ model: AppModel) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { LibraryWarnings(model: model) }
    }
}

/// Changes that could not be stored, and files that could not be read.
private struct LibraryWarnings: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let failure = model.storageFailure {
                Banner("Changes could not be stored.", text: failure) {
                    Button("Retry Saving") { Task { await model.retrySavingHistory() } }
                }
            }
            if let warning = model.libraryWarning {
                Banner("Part of your library could not be read.", text: warning) {
                    if model.foldersAreDamaged {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                model.history.appending(path: "folders.json")
                            ])
                        }
                    }
                } details: {
                    if model.foldersAreDamaged {
                        Text(
                            "Folders cannot be created, renamed or deleted, and transcripts cannot be moved between them, until the file that lists them is repaired or removed, so that nothing writes over it or loses which folder a transcript is in."
                        )
                    }
                }
            }
        }
    }
}

/// One warning across the top of the window, with what can be done about it.
private struct Banner<Action: View, Details: View>: View {
    let title: LocalizedStringKey
    let text: String
    @ViewBuilder let action: Action
    @ViewBuilder let details: Details

    init(
        _ title: LocalizedStringKey, text: String,
        @ViewBuilder action: () -> Action = { EmptyView() },
        @ViewBuilder details: () -> Details = { EmptyView() }
    ) {
        self.title = title
        self.text = text
        self.action = action()
        self.details = details()
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Label {
                    Text("\(Text(title).bold()) \(text)")
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: NoticeState.warning.symbol)
                }
                .notice(NoticeState.warning.tint)
                action
            }
            details
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        Divider()
    }
}

#Preview {
    Banner("Changes could not be stored.", text: "The disk is full.") {
        Button("Retry Saving") {}
    }
}
