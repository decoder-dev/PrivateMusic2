import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Owns the on-device listening statistics of the signed-in account.
///
/// Listening time arrives every half second or so, so it is collected in
/// memory and written into the monthly counters in chunks; the file is saved
/// a few seconds after the last change and whenever the app leaves the
/// foreground. Nothing is sent anywhere.
@MainActor
@Observable
final class ListeningStatsStore {
    private(set) var data = ListeningStatsData()

    /// Seconds are folded into the counters once this much has piled up.
    static let commitThreshold: Double = 10
    private static let saveDelay: Duration = .seconds(5)

    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let directoryOverride: URL?
    @ObservationIgnored private let calendar: () -> Calendar
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var accountID: Int?
    @ObservationIgnored private var pendingSeconds: Double = 0
    @ObservationIgnored private var pendingSubject: ListeningStatsData.Subject?
    @ObservationIgnored private var pendingSince: Date?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isDirty = false

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        calendar: @escaping () -> Calendar = { .current },
        now: @escaping () -> Date = Date.init
    ) {
        self.directoryOverride = directory
        self.fileManager = fileManager
        self.calendar = calendar
        self.now = now
        #if canImport(UIKit)
        // The store lives as long as the app, so the observers are never
        // removed.
        for name in [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification
        ] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveNow() }
            }
        }
        #endif
    }

    // MARK: Account

    func configure(accountID: Int?) {
        guard self.accountID != accountID else { return }
        saveNow()
        self.accountID = accountID
        pendingSeconds = 0
        pendingSubject = nil
        pendingSince = nil
        isDirty = false
        data = ListeningStatsData()
        guard let url = fileURL else { return }
        guard let stored = try? Data(contentsOf: url) else { return }
        do {
            data = try JSONDecoder().decode(ListeningStatsData.self, from: stored)
        } catch {
            AppLog.shared.failure(.app, "Read listening stats", error)
        }
    }

    // MARK: Recording

    /// A track was heard long enough to count as played.
    func recordPlay(_ track: Track) {
        commitPending()
        guard accountID != nil else { return }
        data.addPlay(Self.subject(for: track), at: now(), calendar: calendar())
        scheduleSave()
    }

    /// Real playback time since the last call; cheap enough to call on every
    /// progress tick.
    func recordListening(seconds: TimeInterval, track: Track) {
        guard accountID != nil, seconds.isFinite, seconds > 0 else { return }
        if let pendingSubject, pendingSubject.id != track.id {
            commitPending()
        }
        if pendingSubject == nil {
            pendingSubject = Self.subject(for: track)
            pendingSince = now()
        }
        pendingSeconds += seconds
        if pendingSeconds >= Self.commitThreshold {
            commitPending()
        }
    }

    /// Folds the collected seconds into the counters (pause, track change,
    /// leaving the app).
    func commitPending() {
        defer {
            pendingSeconds = 0
            pendingSubject = nil
            pendingSince = nil
        }
        guard pendingSeconds > 0, let subject = pendingSubject else { return }
        // Stamp with the moment the chunk started, so a chunk that straddles
        // midnight lands on the day the listening began.
        data.addListening(
            seconds: pendingSeconds,
            subject: subject,
            at: pendingSince ?? now(),
            calendar: calendar()
        )
        scheduleSave()
    }

    func clear() {
        pendingSeconds = 0
        pendingSubject = nil
        pendingSince = nil
        saveTask?.cancel()
        saveTask = nil
        isDirty = false
        data = ListeningStatsData()
        if let url = fileURL {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: Persistence

    func saveNow() {
        commitPending()
        saveTask?.cancel()
        saveTask = nil
        guard isDirty, let url = fileURL else { return }
        isDirty = false
        Self.write(data, to: url, fileManager: fileManager)
    }

    private func scheduleSave() {
        isDirty = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveTask = nil
            self?.saveNow()
        }
    }

    private var directoryURL: URL? {
        if let directoryOverride { return directoryOverride }
        return fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("PrivateMusic", isDirectory: true)
            .appendingPathComponent("Stats", isDirectory: true)
    }

    private var fileURL: URL? {
        guard let accountID, let directoryURL else { return nil }
        return directoryURL.appendingPathComponent("listening-\(accountID).json")
    }

    private static func write(
        _ data: ListeningStatsData,
        to url: URL,
        fileManager: FileManager
    ) {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            AppLog.shared.failure(.app, "Write listening stats", error)
        }
    }

    private static func subject(for track: Track) -> ListeningStatsData.Subject {
        ListeningStatsData.Subject(
            id: track.id,
            title: track.title,
            artist: track.artist,
            artistKey: MixFeedbackPolicy.normalized(track.artist),
            artworkURL: track.artworkURL
        )
    }
}
