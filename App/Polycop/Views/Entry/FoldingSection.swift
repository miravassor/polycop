// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A section of the inspector that folds under its title. The form's own fold,
/// `Section(_:isExpanded:)`, draws its arrow in the margin left of the titles
/// and has no option to move it, so this one ends the title's line instead.
struct FoldingSection<Content: View, Footer: View>: View {
    private let title: LocalizedStringKey
    private let section: InspectorSection
    private let reading: ReadingSettings
    private let content: Content
    private let footer: Footer

    init(
        _ title: LocalizedStringKey, section: InspectorSection, reading: ReadingSettings,
        @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.section = section
        self.reading = reading
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        let isFolded = reading.foldedSections.contains(section)
        Section {
            if !isFolded { content }
        } header: {
            // The form sets the title after a section with no rows closer too.
            FoldTitle(title, section: section, reading: reading)
                .padding(.bottom, isFolded ? 6 : 0)
        } footer: {
            if !isFolded { footer }
        }
    }
}

extension FoldingSection where Footer == EmptyView {
    init(
        _ title: LocalizedStringKey, section: InspectorSection, reading: ReadingSettings,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title, section: section, reading: reading, content: content) { EmptyView() }
    }
}

/// A section's title, and the arrow that folds it, pointing down while open. The
/// whole line takes the click.
struct FoldTitle: View {
    private let title: LocalizedStringKey
    private let section: InspectorSection
    private let reading: ReadingSettings
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    init(_ title: LocalizedStringKey, section: InspectorSection, reading: ReadingSettings) {
        self.title = title
        self.section = section
        self.reading = reading
    }

    var body: some View {
        let isFolded = reading.foldedSections.contains(section)
        Button {
            withAnimation(reducesMotion ? nil : .default) { reading.toggleFold(of: section) }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Those of the form's titles, stated: it draws the title after a section
        // with no rows fainter.
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityLabel(title)
        .accessibilityValue(isFolded ? "Hidden" : "Shown")
        .help(isFolded ? "Show this section" : "Hide this section")
    }
}

#Preview {
    let reading = ReadingSettings(defaults: MemoryDefaults())
    Form {
        FoldingSection("Export", section: .export, reading: reading) {
            Toggle("Timecodes", isOn: .constant(true))
        }
        FoldingSection("Details", section: .details, reading: reading) {
            LabeledContent("Added", value: "1 Oct 2026")
        }
    }
    .formStyle(.grouped)
    .frame(width: 360, height: 300)
}
