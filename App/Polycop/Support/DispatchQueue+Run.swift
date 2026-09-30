// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

nonisolated extension DispatchQueue {
    /// Runs blocking work on this queue and waits for its result. The work
    /// holds a thread of this queue, not one of the Swift concurrency pool,
    /// which a C call lasting an hour would starve. The body's error reaches
    /// the caller, and a body that cannot throw makes a call that cannot.
    func run<Value: Sendable, Failure: Error>(
        _ work: @escaping @Sendable () throws(Failure) -> Value
    ) async throws(Failure) -> Value {
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<Value, Failure>, Never>) in
            self.async { continuation.resume(returning: Result(catching: work)) }
        }
        return try result.get()
    }
}
