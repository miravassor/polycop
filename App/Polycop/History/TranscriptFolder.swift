// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The seven macOS Finder tag colours shared by folders and transcript flairs.
nonisolated enum FolderColor: String, CaseIterable, Codable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case gray

    var title: String {
        switch self {
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .blue: String(localized: "Blue")
        case .purple: String(localized: "Purple")
        case .gray: String(localized: "Gray")
        }
    }
}

/// A workflow status, category badge, or coloured tag on a transcript.
nonisolated struct TranscriptFlair: Equatable, Hashable, Codable, Sendable {
    enum Kind: String, CaseIterable, Codable, Sendable {
        case done
        case todo
        case urgent
        case exam

        var title: String {
            switch self {
            case .done: String(localized: "Done")
            case .todo: String(localized: "To Do")
            case .urgent: String(localized: "Urgent")
            case .exam: String(localized: "Exam")
            }
        }

        /// Status flairs are mutually exclusive; a transcript keeps at most one.
        var isStatus: Bool {
            switch self {
            case .done, .todo, .urgent: true
            case .exam: false
            }
        }
    }

    var kind: Kind?
    var title: String
    var color: FolderColor

    private enum CodingKeys: String, CodingKey {
        case kind, title, color
    }

    init(kind: Kind? = nil, title: String, color: FolderColor) {
        self.kind = kind
        self.title = title
        self.color = color
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let rawKind = try container.decodeIfPresent(String.self, forKey: .kind) {
            kind = Kind(rawValue: rawKind)
        } else {
            kind = nil
        }
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        let rawColor = try container.decodeIfPresent(String.self, forKey: .color)
        color = rawColor.flatMap(FolderColor.init(rawValue:)) ?? .gray
    }

    /// Matches presets by kind, named custom tags by case-insensitive title,
    /// and unnamed colour dots by exact colour.
    func matchesIdentity(of other: TranscriptFlair) -> Bool {
        if let kind { return other.kind == kind }
        guard other.kind == nil else { return false }
        if !title.isEmpty {
            return !other.title.isEmpty
                && title.localizedCaseInsensitiveCompare(other.title) == .orderedSame
        }
        return other.title.isEmpty && color == other.color
    }

    static let done = TranscriptFlair(kind: .done, title: "Done", color: .green)
    static let todo = TranscriptFlair(kind: .todo, title: "To Do", color: .orange)
    static let urgent = TranscriptFlair(kind: .urgent, title: "Urgent", color: .red)
    static let exam = TranscriptFlair(kind: .exam, title: "Exam", color: .purple)

    static let presets: [TranscriptFlair] = [.done, .todo, .urgent, .exam]

    var displayTitle: String {
        if let kind { return kind.title }
        return title.isEmpty ? color.title : title
    }

    var symbol: String {
        switch kind {
        case .done: "checkmark.circle.fill"
        case .todo: "circle.dotted.circle.fill"
        case .urgent: "exclamationmark.circle.fill"
        case .exam: "graduationcap.fill"
        case nil: title.isEmpty ? "circle.fill" : "tag.fill"
        }
    }

    private var displayRank: (group: Int, order: Int) {
        let colorOrder = FolderColor.allCases.firstIndex(of: color) ?? 0
        if let kind, let index = Kind.allCases.firstIndex(of: kind) {
            return (0, index)
        }
        return (title.isEmpty ? 2 : 1, colorOrder)
    }

    static func areInDisplayOrder(_ first: TranscriptFlair, _ second: TranscriptFlair) -> Bool {
        let a = first.displayRank
        let b = second.displayRank
        if a.group != b.group { return a.group < b.group }
        if a.group == 1 {
            let nameOrder = first.title.localizedStandardCompare(second.title)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        }
        return a.order < b.order
    }
}

nonisolated struct TranscriptFolder: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var name: String
    var parentID: UUID?
    var color: FolderColor?

    init(id: UUID, name: String, parentID: UUID? = nil, color: FolderColor? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.color = color
    }
}
