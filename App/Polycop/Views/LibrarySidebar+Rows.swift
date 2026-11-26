// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

extension LibrarySidebar {
    func row(_ entry: Entry, folderName: String?) -> some View {
        let targets = targets(of: entry)
        let isWorking = entry.id == model.busyEntry || model.isWaitingForDownload(entry)
        return EntryRow(entry: entry, stage: isWorking ? model.stage : nil, folderName: folderName)
            .tag(AppModel.Pane.entry(entry.id))
            .draggable(DraggedTranscripts(ids: targets))
            .contextMenu { rowContextMenu(entry, targets: targets) }
    }

    @ViewBuilder
    private func rowContextMenu(_ entry: Entry, targets: [Entry.ID]) -> some View {
        let allPinned = targets.allSatisfy { model.entry($0)?.isPinned == true }
        Button(allPinned ? "Unpin" : "Pin") {
            model.setPinned(targets, to: !allPinned)
        }
        TranscriptFlairMenu(model: model, targets: targets) { tagging = targets }
        Divider()
        Button("Move to Folder…") {
            destinationFolder = entry.folderID
            moving = targets
        }
        .disabled(model.foldersAreDamaged)
        if targets.contains(where: { model.entry($0)?.folderID != nil }) {
            Button("Remove from Folder") {
                model.moveEntries(targets, to: nil)
            }
            .disabled(model.foldersAreDamaged)
        }
        // What belongs to one transcript is offered for one: undoing or
        // reverting several at once is not what a right click means.
        if targets.count == 1 {
            Divider()
            Button("Rename Transcript…") {
                entryName = entry.name
                renamedEntry = entry.id
            }
            Button("Undo Last Correction") { model.undo(entry.id) }
                .disabled(!model.canUndo(entry.id) || entry.id == model.busyEntry)
            Button("Revert to Original…") { reverting = entry.id }
                .disabled(!entry.isEdited || entry.id == model.busyEntry)
            Button("Duplicate Transcript") { model.duplicate(entry.id) }
                .disabled(entry.paragraphs.isEmpty || entry.id == model.busyEntry)
        }
        Divider()
        Button("Remove from Library…", role: .destructive) { removing = targets }
            .disabled(targets == [model.busyEntry])
        Divider()
        libraryMenu
    }

    /// The transcripts an action on this row applies to: the whole selection
    /// when the row is part of it, so one menu acts on everything selected, and
    /// the row alone otherwise.
    private func targets(of entry: Entry) -> [Entry.ID] {
        guard selection.contains(.entry(entry.id)), selected.count > 1 else { return [entry.id] }
        return selected
    }

    func drop(_ items: [DraggedTranscripts], into folder: UUID?) -> Bool {
        guard model.moveEntries(items.flatMap(\.ids), to: folder) else { return false }
        if let folder {
            model.revealFolder(folder)
        } else {
            layout.showsUnfiled = true
        }
        return true
    }

    func attempt(_ action: () throws -> Void) {
        do { try action() } catch { model.report(error) }
    }

    var newTranscriptionButton: some View {
        let isSelected = model.pane == .new && selection.isEmpty
        return Button {
            selection.removeAll()
            model.pane = .new
        } label: {
            HStack(spacing: Spacing.icon) {
                Image(systemName: "plus")
                Text("New Transcription").fontWeight(.medium)
                Spacer(minLength: 0)
            }
            .sidebarRowSelection(isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    var searchField: some View {
        HStack(spacing: Spacing.icon) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter library", text: Bindable(layout).searchQuery).textFieldStyle(.plain)
            if !layout.searchQuery.isEmpty {
                Button(action: { layout.searchQuery = "" }) {
                    Label("Clear Search", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear Search")
            }
        }
        .sidebarSearchField()
    }
}
