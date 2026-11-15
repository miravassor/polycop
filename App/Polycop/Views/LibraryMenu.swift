// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Actions shared by the sidebar's context menus and toolbar menu.
struct LibraryMenu: View {
    let model: AppModel
    let newFolder: () -> Void

    var body: some View {
        Button("New Folder…", action: newFolder)
            .disabled(model.foldersAreDamaged)
        LibraryFilterAndSortMenu(model: model)
    }
}

/// Sort and filter menus shared by the sidebar menu and View menu.
struct LibraryFilterAndSortMenu: View {
    let model: AppModel

    var body: some View {
        @Bindable var layout = model.layout
        Menu("Sort By") {
            Picker("Sort By", selection: $layout.sort) {
                Text("Date Added (Newest First)").tag(LibrarySort.newestFirst)
                Text("Date Added (Oldest First)").tag(LibrarySort.oldestFirst)
                Text("Name").tag(LibrarySort.name)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Menu("Filter By") {
            Picker("Filter By", selection: $layout.filter) {
                Text("All Transcripts").tag(LibraryFilter.all)
                Divider()
                Text("Pinned").tag(LibraryFilter.pinned)
                Text("Unreviewed").tag(LibraryFilter.unreviewed)
                Divider()
                ForEach(TranscriptFlair.presets, id: \.self) { flair in
                    if let kind = flair.kind {
                        FlairMenuLabel(flair: flair)
                            .tag(LibraryFilter.flair(kind))
                    }
                }
                if !model.customFlairs.isEmpty {
                    Divider()
                    ForEach(model.customFlairs, id: \.title) { tag in
                        FlairMenuLabel(flair: tag)
                            .tag(LibraryFilter.tag(tag.title))
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Menu("Color") {
                Picker("Color", selection: $layout.filter) {
                    ForEach(FolderColor.allCases, id: \.self) { color in
                        ColorDotLabel(color: color)
                            .tag(LibraryFilter.color(color))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }
}

/// Picks a Finder colour for a folder in its shortcut menu.
struct FolderColorMenu: View {
    let model: AppModel
    let folderID: UUID
    let selected: FolderColor?

    var body: some View {
        Menu("Color") {
            Picker(
                "Color",
                selection: Binding(
                    get: { selected },
                    set: { color in
                        do {
                            try model.setFolderColor(folderID, to: color)
                        } catch {
                            model.report(error)
                        }
                    }
                )
            ) {
                Text("None").tag(FolderColor?.none)
                Divider()
                ForEach(FolderColor.allCases, id: \.self) { color in
                    ColorDotLabel(color: color)
                        .tag(FolderColor?.some(color))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

extension FocusedValues {
    /// The transcripts targeted by the active window: the sidebar's
    /// multi-selection, or the open transcript when one is shown.
    @Entry var selectedTranscripts: [Entry.ID]?
}

/// Menu bar commands to pin or flair the active transcript or selection.
struct LibraryTranscriptCommands: View {
    let model: AppModel
    @FocusedValue(\.selectedTranscripts) private var selectedTranscripts

    private var targets: [Entry.ID] {
        selectedTranscripts ?? []
    }

    var body: some View {
        let allPinned = !targets.isEmpty && targets.allSatisfy { model.entry($0)?.isPinned == true }
        Button(allPinned ? "Unpin" : "Pin") {
            model.setPinned(targets, to: !allPinned)
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(targets.isEmpty)
        TranscriptFlairMenu(model: model, targets: targets, includesShortcuts: true)
            .disabled(targets.isEmpty)
    }
}

/// Applies workflow flairs, custom tags, or colours to one or more transcripts.
struct TranscriptFlairMenu: View {
    let model: AppModel
    let targets: [Entry.ID]
    var includesShortcuts = false
    var newTag: (() -> Void)? = nil

    private var hasAnyFlair: Bool {
        targets.contains { !(model.entry($0)?.flairs ?? []).isEmpty }
    }

    private func isSet(_ flair: TranscriptFlair) -> Bool {
        let entries = targets.compactMap { model.entry($0) }
        return !entries.isEmpty
            && entries.allSatisfy { $0.flairs?.contains { $0.matchesIdentity(of: flair) } == true }
    }

    var body: some View {
        Menu("Flairs and Tags") {
            ForEach(TranscriptFlair.presets, id: \.self) { preset in
                flairToggle(preset)
            }
            if !model.customFlairs.isEmpty {
                Divider()
                ForEach(model.customFlairs, id: \.self) { tag in
                    flairToggle(tag)
                }
            }
            Divider()
            if let newTag {
                Button("New Tag…", action: newTag)
            }
            Menu("Color") {
                ForEach(FolderColor.allCases, id: \.self) { color in
                    flairToggle(TranscriptFlair(kind: nil, title: "", color: color))
                }
            }
            .disabled(targets.isEmpty)
            if hasAnyFlair {
                Divider()
                Button("Clear Flairs") { model.clearFlairs(on: targets) }
            }
        }
    }

    @ViewBuilder
    private func flairToggle(_ flair: TranscriptFlair) -> some View {
        let toggle = Toggle(
            isOn: Binding(
                get: { isSet(flair) },
                set: { _ in model.toggleFlair(flair, on: targets) }
            )
        ) {
            FlairMenuLabel(flair: flair)
        }
        .disabled(targets.isEmpty)

        if includesShortcuts, let kind = flair.kind {
            toggle.keyboardShortcut(kind.shortcutKey, modifiers: [.command, .shift])
        } else {
            toggle
        }
    }
}

private extension TranscriptFlair.Kind {
    var shortcutKey: KeyEquivalent {
        switch self {
        case .done: "d"
        case .todo: "t"
        case .urgent: "u"
        case .exam: "e"
        }
    }
}

/// Adds a named, Finder-coloured custom tag to one or more transcripts.
struct NewTagSheet: View {
    let model: AppModel
    @Binding var targets: [Entry.ID]
    @State private var title = ""
    @State private var color: FolderColor = .blue

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.block) {
            Text("New Tag")
                .font(.sheetTitle)
            TextField("Tag name", text: $title)
            Picker("Color", selection: $color) {
                ForEach(FolderColor.allCases, id: \.self) { option in
                    ColorDotLabel(color: option)
                        .tag(option)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { targets = [] }
                    .keyboardShortcut(.cancelAction)
                Button("Add Tag") {
                    model.addCustomTag(named: title, color: color, to: targets)
                    targets = []
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(Spacing.sheet)
        .frame(width: 380)
    }
}

private struct ColorDotLabel: View {
    let color: FolderColor

    var body: some View {
        Label {
            Text(color.title)
        } icon: {
            color.menuSymbol("circle.fill")
        }
    }
}

private struct FlairMenuLabel: View {
    let flair: TranscriptFlair

    var body: some View {
        Label {
            Text(flair.displayTitle)
        } icon: {
            flair.color.menuSymbol(flair.symbol)
        }
    }
}

/// Clickable sidebar section header matching `FoldTitle` so sections fold
/// visibly instead of relying on macOS hover-only sidebar chevrons.
struct LibrarySectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @Binding var isExpanded: Bool
    var isCollapsible = true
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    init(
        _ title: LocalizedStringKey,
        isExpanded: Binding<Bool>,
        isCollapsible: Bool = true,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.isCollapsible = isCollapsible
        self.trailing = trailing
    }

    var body: some View {
        let shown = isExpanded || !isCollapsible
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 0) {
                    Text(title)
                    Spacer(minLength: 8)
                    if Trailing.self == EmptyView.self, isCollapsible {
                        FoldChevron(isExpanded: shown)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isCollapsible)
            .accessibilityLabel(title)
            .accessibilityValue(shown ? "Shown" : "Hidden")
            .accessibilityAddTraits(.isHeader)
            .help(isCollapsible ? (shown ? "Hide this section" : "Show this section") : "")
            trailing()
            if Trailing.self != EmptyView.self, isCollapsible {
                Button(action: toggle) {
                    FoldChevron(isExpanded: shown)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
                .help(shown ? "Hide this section" : "Show this section")
            }
        }
        .padding(.trailing, 10)
    }

    private func toggle() {
        guard isCollapsible else { return }
        withAnimation(reducesMotion ? nil : .default) { isExpanded.toggle() }
    }
}

struct LibraryToolbar<MenuContent: View>: ViewModifier {
    let isShown: Bool
    let isFiltered: Bool
    @ViewBuilder let menu: () -> MenuContent

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.toolbar {
                if isShown {
                    ToolbarItem { filterMenu }
                        .sharedBackgroundVisibility(.hidden)
                }
            }
        } else {
            content.toolbar {
                if isShown {
                    ToolbarItem { filterMenu }
                }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            menu()
        } label: {
            Label(
                "Filter and Sort",
                systemImage: isFiltered
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease"
            )
        }
        .menuIndicator(.hidden)
        .help("Filter and Sort")
    }
}

#Preview {
    // An empty library and glossaries of its own, never the user's.
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    Menu("Library") {
        LibraryMenu(
            model: AppModel(
                history: folder.appending(path: "History"),
                glossaries: folder.appending(path: "Glossaries"),
                defaults: MemoryDefaults()),
            newFolder: {})
    }
}
