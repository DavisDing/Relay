import Foundation
import Dispatch

/// Bounded, non-secret observations of the last load and commit attempt.
/// Not Codable: diagnostics never enter local JSON, sync data or logs.
public struct RepositoryPerformanceDiagnostics: Sendable, Equatable {
    public internal(set) var accountCount = 0
    public internal(set) var historyCount = 0
    public internal(set) var maximumHistoryCountPerAccount = 0
    /// Bytes read/written for the committed local JSON (not the iCloud file).
    public internal(set) var fileBytes = 0
    /// Initial repository load, including permission checks, decoding and index construction.
    /// This does not measure RelayStore's UI projection/reload.
    public internal(set) var reloadMilliseconds: Double = 0
    /// Encoding, atomic file write and index construction for the last attempt.
    public internal(set) var commitMilliseconds: Double?
    public internal(set) var lastCommitSucceeded: Bool?

    /// Advisory only: no automatic pruning, migration or runtime behavior changes.
    /// Repeated observations should guide investigation, not a single slow sample.
    public static let suggestedFileBytes = 5_000_000
    public static let suggestedHistoryCountPerAccount = 3_000
    public static let suggestedOperationMilliseconds: Double = 200

    public enum Advisory: Sendable, Equatable {
        case fileSize, perAccountHistory, reloadDuration, commitDuration
    }

    public var advisories: [Advisory] {
        var result: [Advisory] = []
        if fileBytes > Self.suggestedFileBytes { result.append(.fileSize) }
        if maximumHistoryCountPerAccount > Self.suggestedHistoryCountPerAccount { result.append(.perAccountHistory) }
        if reloadMilliseconds > Self.suggestedOperationMilliseconds { result.append(.reloadDuration) }
        if let commitMilliseconds, commitMilliseconds > Self.suggestedOperationMilliseconds {
            result.append(.commitDuration)
        }
        return result
    }

    public init() {}
}

/// Monotonic timing avoids wall-clock adjustments during an observation.
enum RepositoryPerformanceClock {
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(now() - start) / 1_000_000
    }
}
