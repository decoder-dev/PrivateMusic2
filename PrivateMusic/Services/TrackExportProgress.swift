import Foundation

/// Honest, granular export progress. Never fakes a percentage: indeterminate
/// stages report no fraction, and segment downloads report exact
/// completed/total counters.
enum TrackExportProgress: Equatable, Sendable {
    case resolvingSource
    case copyingLocalFile
    case downloadingDirectFile
    case downloadingSegments(completed: Int, total: Int)
    case convertingToM4A
}

typealias TrackExportProgressHandler =
    @MainActor @Sendable (TrackExportProgress) -> Void
