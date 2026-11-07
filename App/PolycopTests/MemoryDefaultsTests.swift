// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI
import Testing

@testable import Polycop

/// Writes down each value its key takes, as a view reading a setting is told.
private final class Observer: NSObject {
    var values: [Any] = []

    override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        values.append(change?[.newKey] ?? NSNull())
    }
}

/// The models read settings through the typed getters, and the views through
/// `@AppStorage`, so settings in memory serve both as the user's would.
@Test func settingsInMemoryReadBackThroughEveryGetter() {
    let settings = MemoryDefaults()
    let shown = AppStorage(wrappedValue: true, "someSetting", store: settings)
    shown.wrappedValue = false
    settings.set(2, forKey: "launches")
    settings.set(1.5, forKey: "speed")
    settings.set("Word", forKey: "format")

    #expect(settings.object(forKey: "someSetting") as? Bool == false)
    #expect(!settings.bool(forKey: "someSetting"))
    #expect(settings.integer(forKey: "launches") == 2)
    #expect(settings.double(forKey: "speed") == 1.5)
    #expect(settings.string(forKey: "format") == "Word")
    settings.removeObject(forKey: "speed")
    #expect(settings.object(forKey: "speed") == nil)
}

/// A view showing a setting is drawn again when it changes: `@AppStorage`
/// observes its key.
@Test func settingsInMemoryTellTheirObservers() {
    let settings = MemoryDefaults()
    let observer = Observer()
    settings.addObserver(observer, forKeyPath: "speed", options: [.new], context: nil)
    defer { settings.removeObserver(observer, forKeyPath: "speed") }

    settings.set(1.5, forKey: "speed")
    settings.set(2.0, forKey: "speed")

    #expect(observer.values as? [Double] == [1.5, 2.0])
}
