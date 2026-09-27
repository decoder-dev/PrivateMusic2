import Foundation
import Observation

struct LibraryDownloadSnapshot: Codable, Sendable {
    var pending: [Track] = []
    var nextOffset: Int? = 0
    var completed = 0
    var total = 0
    var wifiOnly = true
    var finished: Bool { pending.isEmpty && nextOffset == nil }
}

@MainActor @Observable
final class LibraryDownloadJob {
    private(set) var snapshot = LibraryDownloadSnapshot()
    private(set) var running = false
    private(set) var error: String?
    private(set) var hasJob = false
    @ObservationIgnored private var accountID: Int?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("LibraryDownloads", isDirectory: true)
    }

    func configure(accountID: Int?) {
        guard self.accountID != accountID else { return }
        pause()
        self.accountID = accountID
        snapshot = LibraryDownloadSnapshot(); hasJob = false; error = nil
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(LibraryDownloadSnapshot.self, from: data) {
            snapshot = saved; hasJob = true
        }
    }

    func pause() {
        generation = UUID()
        task?.cancel(); task = nil; running = false
    }

    func cancel() {
        pause()
        if let file { try? FileManager.default.removeItem(at: file) }
        snapshot = LibraryDownloadSnapshot(); hasJob = false; error = nil
    }

    func start(environment: AppEnvironment, wifiOnly: Bool) {
        guard !running, let accountID,
              accountID == environment.sessionStore.resolvedOfflineAccountID else { return }
        if !hasJob || snapshot.finished { snapshot = LibraryDownloadSnapshot() }
        snapshot.wifiOnly = wifiOnly; hasJob = true; error = nil
        do { try persist() } catch { self.error = error.localizedDescription; return }
        running = true
        let request = UUID(); generation = request
        task = Task { [weak self, weak environment] in
            guard let self, let environment else { return }
            defer { if self.generation == request { self.running = false; self.task = nil } }
            do {
                while !self.snapshot.finished {
                    try Task.checkCancellation()
                    guard self.generation == request, self.accountID == accountID,
                          environment.sessionStore.resolvedOfflineAccountID == accountID else { throw CancellationError() }
                    guard environment.networkMonitor.state != .offline else { throw APIError.offline }
                    if self.snapshot.wifiOnly,
                       environment.networkMonitor.transport != .wifi && environment.networkMonitor.transport != .wired {
                        throw APIError.server(code: 0, message: L10n.text("features.download.need_wifi"))
                    }
                    if let track = self.snapshot.pending.first {
                        // Existing files are promoted to manual retention without re-downloading.
                        if environment.offlineStore.contains(track) {
                            try await environment.offlineStore.download(track, userAgent: environment.sessionStore.userAgent)
                        } else {
                            try await environment.downloadForOffline(track)
                        }
                        try Task.checkCancellation()
                        guard self.generation == request else { throw CancellationError() }
                        self.snapshot.pending.removeFirst()
                        self.snapshot.completed += 1
                        try self.persist()
                    } else if let offset = self.snapshot.nextOffset {
                        let page = try await environment.withAuthorizedToken { token in
                            try await environment.musicService.library(accessToken: token, offset: offset, count: 200)
                        }
                        try Task.checkCancellation()
                        guard self.generation == request else { throw CancellationError() }
                        if let next = page.nextOffset, next <= offset { throw APIError.invalidResponse }
                        var seen = Set<String>()
                        self.snapshot.pending = page.items.filter { seen.insert($0.id).inserted }
                        self.snapshot.total = max(page.totalCount, self.snapshot.completed + self.snapshot.pending.count)
                        self.snapshot.nextOffset = page.nextOffset
                        try self.persist()
                    }
                }
            } catch is CancellationError {
            } catch {
                if self.generation == request { self.error = error.localizedDescription }
            }
        }
    }

    private var file: URL? { accountID.map { directory.appendingPathComponent("\($0).json") } }
    private func persist() throws {
        guard let file else { throw APIError.unauthorized }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
