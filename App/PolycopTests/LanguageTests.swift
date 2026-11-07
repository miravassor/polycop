// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

/// A language shows only beside a model told it, before a start and after.
@Test(arguments: [
    (ModelCatalog.turbo, true), (ModelCatalog.qwen, true),
    (ModelCatalog.moss, false), (ModelCatalog.voxtral, false),
])
@MainActor
func theSummaryNamesALanguageOnlyForAModelToldIt(chosen: Model, names: Bool) {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(
        history: root.appending(path: "History"), glossaries: root.appending(path: "Glossaries"),
        defaults: MemoryDefaults())
    model.selected = chosen.id
    model.language = "de"
    #expect(StartBar.summary(of: model).contains("German") == names)

    let scheduled = Entry(
        recording: URL(filePath: "/made/up.m4a"), modelFile: chosen.id, glossary: nil,
        skipsSilence: false, subtitles: false, language: "de")
    #expect(StartBar.summary(of: scheduled).contains("German") == names)
}

/// Automatic is remembered as a language is, and names none in the summary.
@Test(arguments: [ModelCatalog.turbo, ModelCatalog.qwen])
@MainActor
func automaticIsRememberedAndNamesNoLanguage(chosen: Model) {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appending(path: "History")
    let glossaries = root.appending(path: "Glossaries")
    let defaults = MemoryDefaults()
    let first = AppModel(history: history, glossaries: glossaries, defaults: defaults)
    first.language = DecodingSettings.automaticLanguage

    let next = AppModel(history: history, glossaries: glossaries, defaults: defaults)
    next.selected = chosen.id
    #expect(next.language == DecodingSettings.automaticLanguage)
    #expect(next.toldLanguage == nil)
    #expect(StartBar.summary(of: next).contains(chosen.name))
    #expect(!StartBar.summary(of: next).contains("auto"))
}

@Test func anEngineThatDetectsTheLanguageSaysSo() {
    for engine in Engine.allCases {
        #expect(engine.features.contains("Detects the language") == engine.detectsLanguage)
    }
}
