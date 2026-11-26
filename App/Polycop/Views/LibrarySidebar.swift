// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Sidebar list of pinned transcripts, unfiled items, folders, search, and filters.
/// Given no closure, which SwiftUI may take as new at each run of the window and
/// run this body for: its folder actions ask the model.
struct LibrarySidebar: View {
    let model: AppModel
    @Binding var selection: Set<AppModel.Pane>
    @Binding var removing: [Entry.ID]
    @Binding var moving: [Entry.ID]
    @Binding var destinationFolder: UUID?
    @Binding var tagging: [Entry.ID]
    @Binding var renamedEntry: Entry.ID?
    @Binding var entryName: String
    @Binding var reverting: Entry.ID?

    @State private var highlighted: UUID?
    @State private var highlightsUnfiled = false

    var layout: WindowLayout { model.layout }
    /// The visible transcripts selected, in the order the sidebar shows them.
    var selected: [Entry.ID] {
        model.visibleEntryOrder.filter { selection.contains(.entry($0)) }
    }
    private var pinnedEntries: [LibraryItem] { model.pinnedEntries }
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
        // For RedrawTests, in the test host only.
        let _ = Redraws.count(.library, in: model)
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
        .onChange(of: model.visibleSelectablePanes) { _, visiblePanes in
            guard selection.count > 1 else { return }
            let kept = selection.intersection(visiblePanes)
            if kept.isEmpty {
                selection =
                    (model.pane != .new && visiblePanes.contains(model.pane))
                    ? [model.pane] : []
            } else if kept != selection {
                selection = kept
            }
        }
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
                    model.addFolder()
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
                FlairIcons(flairs: flairs, maxCount: 4)
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
            Button("New Subfolder…") { model.addFolder(in: folder.id) }
                .disabled(model.foldersAreDamaged)
        }
        FolderColorMenu(model: model, folderID: folder.id, selected: folder.color)
            .disabled(model.foldersAreDamaged)
        Divider()
        Button("Rename Folder…") { model.askToRenameFolder(folder.id) }
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

    var libraryMenu: some View {
        LibraryMenu(model: model)
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
            selection: .constant([]),
            removing: .constant([]), moving: .constant([]),
            destinationFolder: .constant(nil), tagging: .constant([]),
            renamedEntry: .constant(nil), entryName: .constant(""),
            reverting: .constant(nil)
        )
    } detail: {
        Text("Detail")
    }
}
