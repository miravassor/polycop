// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Metal

/// What a model is likely to cost, against what Metal recommends on this Mac.
///
/// whisper.cpp returns a null context for every failure alike, so a model
/// plainly too large is caught before the call. The check only approximates
/// whether a model fits.
nonisolated enum Memory {
    /// Metal's recommended working set for this device. Apple defines it as a
    /// recommendation rather than free memory, and it shrinks under pressure
    /// from other apps. `maxBufferLength`, the limit for one allocation, is
    /// lower again.
    static var recommendedBudget: Int64 {
        guard let device = MTLCreateSystemDefaultDevice() else { return 0 }
        return Int64(device.recommendedMaxWorkingSetSize)
    }

    static func isLikelyToFit(_ model: Model) -> Bool {
        fits(model.peakBytes)
    }

    /// For models loaded together, whose peaks add up.
    static func areLikelyToFit(_ models: Model...) -> Bool {
        fits(models.reduce(0) { $0 + $1.peakBytes })
    }

    private static func fits(_ peak: Int64) -> Bool {
        let budget = recommendedBudget
        return budget == 0 || peak < budget
    }

    static func describe(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
