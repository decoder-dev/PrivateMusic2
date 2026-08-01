import Foundation

/// Abstraction over share payload preparation so the share flow view model
/// is testable without the full `AppEnvironment`.
@MainActor
protocol TrackSharePreparing: AnyObject {
    func prepareSharePayload(
        for track: Track,
        progress: TrackExportProgressHandler?
    ) async throws -> TrackSharePayload

    func removeSharePayload(
        _ payload: TrackSharePayload
    ) async
}

extension AppEnvironment: TrackSharePreparing {}
