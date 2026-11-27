// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

extension LibrarySidebar {
    func row(_ item: LibraryItem, folderName: String?, selected: [Entry.ID]) -> some View {
        let targets = targets(of: item, selected: selected)
        let isWorking = item.id == model.busyEntry || model.isWaitingForDownload(item)
        return EntryRow(item: item, stage: isWorking ? model.stage : nil, folderName: folderName)
            .tag(AppModel.Pane.entry(item.id))
            .draggable(DraggedTranscripts(ids: targets))
            .contextMenu { rowContextMenu(item, targets: targets) }
    }

    @ViewBuilder
    private func rowContextMenu(_ item: LibraryItem, targets: [Entry.ID]) -> some View {
        let allPinned = targets.allSatisfy { model.libraryItem($0)?.isPinned == true }
        Button(allPinned ? "Unpin" : "Pin") {
            model.setPinned(targets, to: !allPinned)
        }
        TranscriptFlairMenu(model: model, targets: targets) { tagging = targets }
        Divider()
        Button("Move to Folder…") {
            destinationFolder = item.folderID
            moving = targets
        }
        .disabled(model.foldersAreDamaged)
        if targets.contains(where: { model.libraryItem($0)?.folderID != nil }) {
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
                entryName = item.name
                renamedEntry = item.id
            }
            Button("Undo Last Correction") { model.undo(item.id) }
                .disabled(!model.canUndo(item.id) || item.id == model.busyEntry)
            Button("Revert to Original…") { reverting = item.id }
                .disabled(!item.isEdited || item.id == model.busyEntry)
            Button("Duplicate Transcript") { model.duplicate(item.id) }
                .disabled(!item.hasText || item.id == model.busyEntry)
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
    private func targets(of item: LibraryItem, selected: [Entry.ID]) -> [Entry.ID] {
        guard selection.count > 1, selection.contains(.entry(item.id)), selected.count > 1 else {
            return [item.id]
        }
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
