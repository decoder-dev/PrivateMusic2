import Foundation
import Observation

struct VKListeningEvent: Codable, Sendable {
    let event: String
    let audioID: String
    let uuid: String
    let startTime: Double
    let playbackStartedAt: Double
    let position: Double
    let duration: Double
    let trackCode: String?
    let streamingType: String
    let shuffle: Int
    let repeatMode: String
    let reason: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case event = "e", audioID = "audio_id", uuid, position, duration, shuffle, reason, state
        case startTime = "start_time", playbackStartedAt = "playback_started_at"
        case trackCode = "track_code", streamingType = "streaming_type", repeatMode = "repeat"
    }
}

/// No durable listening-event spool: turning consent off discards unsent events.
/// A rejected integration stops until the user retries; playback is never blocked.
@MainActor @Observable
final class VKPlaybackIntegration {
    private(set) var broadcastError: String?
    private(set) var reportingError: String?
    @ObservationIgnored private var observation: ObservationLoop.Token?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var commands: [Command] = []
    @ObservationIgnored private var credential: String?
    @ObservationIgnored private var accountID: Int?
    @ObservationIgnored private var lastBroadcastID: String?
    @ObservationIgnored private var lastBroadcastEnabled = false
    @ObservationIgnored private var lastReportingEnabled = false
    @ObservationIgnored private var active: Listening?

    private struct Listening {
        let track: Track
        let uuid = UUID().uuidString
        let started = Date()
        let position: Double
    }
    private enum Command {
        case broadcast(Track?)
        case events([VKListeningEvent])
    }

    func start(environment: AppEnvironment) {
        observation = ObservationLoop.start { [weak self, weak environment] in
            guard let self, let environment else { return }
            self.update(environment)
        }
    }

    func retry(environment: AppEnvironment) {
        if broadcastError != nil && !environment.settings.vkBroadcastEnabled {
            commands.append(.broadcast(nil))
        }
        broadcastError = nil
        reportingError = nil
        lastBroadcastEnabled = false
        lastBroadcastID = nil
        update(environment)
    }

    private func update(_ environment: AppEnvironment) {
        let settings = environment.settings
        let player = environment.player
        let token = environment.sessionStore.accessToken
        let owner = environment.sessionStore.resolvedOfflineAccountID
        let track = player.currentTrack
        let playing = player.isPlaying && !player.isBuffering && !environment.isShareSessionActive
        let broadcastEnabled = settings.vkBroadcastEnabled
        let reportingEnabled = settings.vkReportingEnabled
        if credential != token || accountID != owner {
            let changedAccount = accountID != nil && accountID != owner
            worker?.cancel(); worker = nil; commands.removeAll(); active = nil
            credential = token; accountID = owner
            lastBroadcastID = nil; lastBroadcastEnabled = false
            broadcastError = nil; reportingError = nil
            if changedAccount {
                settings.vkBroadcastEnabled = false
                settings.vkReportingEnabled = false
                return
            }
        }
        guard token != nil else { return }
        if broadcastEnabled != lastBroadcastEnabled, broadcastError != nil { broadcastError = nil }
        if !reportingEnabled {
            if reportingError != nil { reportingError = nil }
            active = nil
            commands.removeAll { if case .events = $0 { return true }; return false }
        }
        let desiredTrack = broadcastEnabled && playing ? track : nil
        if broadcastError == nil,
           desiredTrack?.id != lastBroadcastID || (lastBroadcastEnabled && !broadcastEnabled) {
            commands.removeAll { if case .broadcast = $0 { return true }; return false }
            commands.append(.broadcast(desiredTrack))
            lastBroadcastID = desiredTrack?.id
        }
        lastBroadcastEnabled = broadcastEnabled
        if reportingEnabled && reportingError == nil {
            if let previous = active, !playing || previous.track.id != track?.id {
                let listened = min(max(0, previous.track.duration), max(0, Date().timeIntervalSince(previous.started)))
                commands.append(.events([event(previous, name: "music_stop_playback",
                    duration: listened, environment: environment)]))
                active = nil
            }
            if active == nil, playing, let track {
                let next = Listening(track: track, position: max(0, player.elapsedTime))
                active = next
                commands.append(.events([event(next, name: "music_start_playback", duration: 0,
                    environment: environment)]))
            }
        }
        lastReportingEnabled = reportingEnabled
        if commands.count > 32 { commands.removeFirst(commands.count - 32) }
        drain(environment)
    }

    private func event(_ listening: Listening, name: String, duration: Double,
                       environment: AppEnvironment) -> VKListeningEvent {
        VKListeningEvent(event: name, audioID: listening.track.id, uuid: listening.uuid,
            startTime: listening.position, playbackStartedAt: listening.started.timeIntervalSince1970,
            position: listening.position + duration, duration: duration, trackCode: listening.track.trackCode,
            streamingType: environment.offlineStore.contains(listening.track) ? "offline" : "online",
            shuffle: environment.player.shuffleEnabled ? 1 : 0,
            repeatMode: String(describing: environment.player.repeatMode), reason: "user", state: "app")
    }

    private func drain(_ environment: AppEnvironment) {
        guard worker == nil, !commands.isEmpty, let token = credential else { return }
        worker = Task { [weak self, weak environment] in
            guard let self, let environment else { return }
            defer { if self.credential == token { self.worker = nil } }
            while !Task.isCancelled, self.credential == token, !self.commands.isEmpty {
                let command = self.commands.removeFirst()
                do {
                    switch command {
                    case let .broadcast(track):
                        guard self.broadcastError == nil else { continue }
                        try await environment.musicService.broadcast(track: track, accessToken: token)
                    case let .events(events):
                        guard environment.settings.vkReportingEnabled, self.reportingError == nil else { continue }
                        try await environment.musicService.reportPlayback(events: events, accessToken: token)
                    }
                } catch {
                    guard !Task.isCancelled, self.credential == token else { return }
                    switch command {
                    case .broadcast: self.broadcastError = error.localizedDescription
                    case .events: self.reportingError = error.localizedDescription; self.active = nil
                    }
                }
            }
        }
    }
}
