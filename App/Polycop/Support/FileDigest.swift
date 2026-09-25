// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import os

/// Computes the SHA-256 of a file, read in blocks because models and other
/// files can be too large to hold in memory.
nonisolated enum FileDigest {
    static func sha256(
        of file: URL, until cancelled: OSAllocatedUnfairLock<Bool>? = nil
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            if cancelled?.withLock({ $0 }) == true { throw CancellationError() }
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
