// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Sidebar list of pinned transcripts, unfiled items, folders, search, and filters.
struct LibrarySidebar: View {
    let model: AppModel
    @Binding var selection: Set<AppModel.Pane>
    let selected: [Entry.ID]
    @Binding var removing: [Entry.ID]
    @Binding var moving: [Entry.ID]
    @Binding var destinationFolder: UUID?
    @Binding var tagging: [Entry.ID]
    @Binding var renamedEntry: Entry.ID?
    @Binding var entryName: String
    @Binding var reverting: Entry?
    let newFolder: (UUID?) -> Void
    let renameFolder: (TranscriptFolder) -> Void

    @State private var highlighted: UUID?
    @State private var highlightsUnfiled = false

    private var layout: WindowLayout { model.layout }
    private var pinnedEntries: [Entry] { model.pinnedEntries }
    private var visibleRoots: [TranscriptFolder] {
        model.rootFolders.filter { model.shouldShowFolder($0.id) }
    }

    private var showsUnfiledSection: Bool {
        if !model.isFilteringLibrary { return true }
        return model.hasEntries(in: nil)
            || !model.visibleUnavailable(in: nil).isEmpty
            || !model.visibleUnidentifiedFiles.isEmpty
    }

    private var showsFoldersSection: Bool {
        !model.isFilteringLibrary || !visibleRoots.isEmpty
    }

    private var hasNoMatches: Bool {
        model.isFilteringLibrary
            && pinnedEntries.isEmpty
            && !showsUnfiledSection
            && visibleRoots.isEmpty
            && model.visibleRecentlyDeleted.isEmpty
            && model.visibleRemovedUnavailable.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                newTranscriptionButton
                Divider()
                searchField
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 6)

            List(selection: $selection) {
                if layout.filter != .all { filterBanner }
                if !pinnedEntries.isEmpty { pinnedSection }
                if showsUnfiledSection { unfiledSection }
                if showsFoldersSection { foldersSection }
                if hasNoMatches { emptyNote("No matching transcripts") }
                RecentlyDeletedSection(model: model)
            }
            .listStyle(.sidebar)
        }
        .contextMenu { libraryMenu }
        .modifier(LibraryToolbar(model: model))
    }

    private var filterBanner: some View {
        HStack(spacing: Spacing.icon) {
            Label(layout.filter.title, systemImage: "line.3.horizontal.decrease.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("Clear") { layout.filter = .all }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 2)
    }

    private var pinnedSection: some View {
        Section {
            if model.isFilteringLibrary || layout.showsPinned {
                ForEach(pinnedEntries) { entry in
                    row(entry, folderName: model.folderPath(of: entry.folderID))
                }
            }
        } header: {
            LibrarySectionHeader(
                "Pinned",
                isExpanded: Bindable(layout).showsPinned,
                isCollapsible: !model.isFilteringLibrary
            )
            .contextMenu { libraryMenu }
        }
    }

    private var unfiledSection: some View {
        Section {
            if model.isFilteringLibrary || layout.showsUnfiled {
                let entries = model.entries(in: nil)
                if entries.isEmpty, model.visibleUnavailable(in: nil).isEmpty,
                    model.visibleUnidentifiedFiles.isEmpty
                {
                    emptyNote(
                        model.hasPinnedEntries(in: nil)
                            ? "Pinned above" : "Nothing outside a folder")
                }
                UnavailableRows(model: model, folder: nil)
                ForEach(entries) { entry in row(entry, folderName: nil) }
            }
        } header: {
            LibrarySectionHeader(
                model.folders.isEmpty ? "Library" : "Unfiled",
                isExpanded: Bindable(layout).showsUnfiled,
                isCollapsible: !model.isFilteringLibrary
            )
            .dropTargetHighlight(highlightsUnfiled)
            .contextMenu { libraryMenu }
            .dropDestination(for: DraggedTranscripts.self) { items, _ in
                drop(items, into: nil)
            } isTargeted: {
                highlightsUnfiled = $0
            }
        }
    }

    private var foldersSection: some View {
        Section {
            if model.isFilteringLibrary || layout.showsFolders {
                if model.folders.isEmpty, !model.isFilteringLibrary {
                    emptyNote("No folders yet")
                }
                ForEach(visibleRoots) { root in
                    let subfolders = model.subfolders(of: root.id)
                        .filter { model.shouldShowFolder($0.id) }
                    folderGroup(root) {
                        ForEach(subfolders) { subfolder in
                            folderGroup(subfolder) {
                                folderItems(subfolder.id, hasSubfolders: false)
                            }
                        }
                        folderItems(root.id, hasSubfolders: !subfolders.isEmpty)
                    }
                }
            }
        } header: {
            // The button sits on the header's own line cleanly beside the fold chevron.
            LibrarySectionHeader(
                "Folders",
                isExpanded: Bindable(layout).showsFolders,
                isCollapsible: !model.isFilteringLibrary
            ) {
                Button {
                    newFolder(nil)
                } label: {
                    Label("New Folder…", systemImage: "folder.badge.plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(model.foldersAreDamaged)
                .help("New Folder…")
            }
            .contextMenu { libraryMenu }
        }
    }

    private func folderGroup<Content: View>(
        _ folder: TranscriptFolder, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { model.isFolderExpanded(folder.id) },
                set: { model.setFolderExpanded(folder.id, to: $0) }
            ),
            content: content,
            label: { folderLabel(folder) }
        )
    }

    @ViewBuilder
    private func folderItems(_ folderID: UUID, hasSubfolders: Bool) -> some View {
        let entries = model.entries(in: folderID)
        let unavailable = model.visibleUnavailable(in: folderID)
        if entries.isEmpty, unavailable.isEmpty, !hasSubfolders {
            let emptyLabel: LocalizedStringKey =
                if model.isFilteringLibrary, model.holdsTranscripts(folderID) {
                    "No matches"
                } else if model.hasPinnedEntries(in: folderID) {
                    "Pinned above"
                } else {
                    "Empty folder"
                }
            emptyNote(emptyLabel)
        }
        UnavailableRows(model: model, folder: folderID)
        ForEach(entries) { entry in row(entry, folderName: nil) }
    }

    private func folderLabel(_ folder: TranscriptFolder) -> some View {
        let flairs = model.collapsedFolderFlairs(in: folder.id)
        let label = FlairIcons.folderAccessibilityLabel(folder.name, collapsedFlairs: flairs)
        return HStack(spacing: Spacing.icon) {
            Group {
                if let color = folder.color {
                    Label {
                        Text(folder.name)
                    } icon: {
                        Image(systemName: "folder.fill").foregroundStyle(color.tint)
                    }
                } else {
                    Label(folder.name, systemImage: "folder")
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            if !flairs.isEmpty {
                Spacer(minLength: 0)
                FlairIcons(flairs: flairs, maxCount: 4).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .dropTargetHighlight(highlighted == folder.id)
        .dropDestination(for: DraggedTranscripts.self) { items, _ in
            drop(items, into: folder.id)
        } isTargeted: {
            highlighted = $0 ? folder.id : nil
        }
        .contextMenu { folderContextMenu(folder) }
    }

    @ViewBuilder
    private func folderContextMenu(_ folder: TranscriptFolder) -> some View {
        if model.canAddSubfolder(to: folder.id) {
            Button("New Subfolder…") { newFolder(folder.id) }
                .disabled(model.foldersAreDamaged)
        }
        FolderColorMenu(model: model, folderID: folder.id, selected: folder.color)
            .disabled(model.foldersAreDamaged)
        Divider()
        Button("Rename Folder…") { renameFolder(folder) }
            .disabled(model.foldersAreDamaged)
        Button("Delete Empty Folder", role: .destructive) {
            attempt { try model.removeFolder(folder.id) }
        }
        .disabled(model.foldersAreDamaged || model.holdsTranscripts(folder.id))
        Divider()
        libraryMenu
    }

    private func emptyNote(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .contextMenu { libraryMenu }
    }

    private var libraryMenu: some View {
        LibraryMenu(model: model)
    }
}

extension LibrarySidebar {
    private func row(_ entry: Entry, folderName: String?) -> some View {
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
            Button("Revert to Original…") { reverting = entry }
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

    private func drop(_ items: [DraggedTranscripts], into folder: UUID?) -> Bool {
        guard model.moveEntries(items.flatMap(\.ids), to: folder) else { return false }
        if let folder {
            model.revealFolder(folder)
        } else {
            layout.showsUnfiled = true
        }
        return true
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { model.report(error) }
    }

    private var newTranscriptionButton: some View {
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

    private var searchField: some View {
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

#Preview {
    // An empty library and glossaries of its own, never the user's.
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    NavigationSplitView {
        LibrarySidebar(
            model: AppModel(
                history: folder.appending(path: "History"),
                glossaries: folder.appending(path: "Glossaries"),
                defaults: MemoryDefaults()),
            selection: .constant([]), selected: [],
            removing: .constant([]), moving: .constant([]),
            destinationFolder: .constant(nil), tagging: .constant([]),
            renamedEntry: .constant(nil), entryName: .constant(""),
            reverting: .constant(nil),
            newFolder: { _ in }, renameFolder: { _ in }
        )
    } detail: {
        Text("Detail")
    }
}
