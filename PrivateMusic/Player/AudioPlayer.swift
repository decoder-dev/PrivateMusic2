import AVFoundation
import Combine
import MediaPlayer

enum RepeatMode: String, CaseIterable {
    case off
    case all
    case one

    var systemImage: String {
        self == .one ? "repeat.1" : "repeat"
    }
}

/// What started the current queue, for display in the full-screen player.
/// Callers that start playback from a named collection pass the matching
/// case; anything else (search results, recommendations, artist tracks,
/// offline files, an "open player" context-menu action, …) is left `nil`
/// and treated as an implicit automix seeded by the tapped track — see
/// `AudioPlayer.queueContextTitle`.
enum QueueSource: Equatable {
    case mix(title: String)
    case playlist(title: String)
    case album(title: String)
    case history
}

enum QueueSourceTitle {
    static func isUsable(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Playback route policy for wired / wireless headphone disconnects.
///
/// Apple documents that media apps must pause when headphones are removed so
/// audio does not continue through the built-in speaker. See:
/// https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes
/// (`AVAudioSession.routeChangeNotification` +
/// `AVAudioSession.RouteChangeReason.oldDeviceUnavailable`).
///
/// Single-AirPod Automatic Ear Detection is delivered as a remote pause /
/// interruption rather than a full route loss; `MPRemoteCommandCenter` and
/// `setPrefersInterruptionOnRouteDisconnect(true)` cover that path.
enum AudioRoutePolicy {
    static let minimumAudibleVolume: Float = 0.001

    static func shouldPause(
        volume: Float,
        enabled: Bool,
        isPlaying: Bool,
        outputPortTypes: [AVAudioSession.Port]
    ) -> Bool {
        enabled
            && isPlaying
            && volume <= minimumAudibleVolume
            && outputPortTypes.contains(where: supportsSystemVolumePause)
            && !outputPortTypes.contains(where: isExternalPlayback)
    }

    static func shouldResumeAfterMinimumVolumePause(
        volume: Float,
        enabled: Bool,
        pausedForMinimumVolume: Bool,
        playbackIntended: Bool,
        hasCurrentTrack: Bool,
        isPlaying: Bool,
        outputPortTypes: [AVAudioSession.Port],
        isAudioInterrupted: Bool = false,
        allowsAutomaticResume: Bool = true
    ) -> Bool {
        guard pausedForMinimumVolume,
              playbackIntended,
              hasCurrentTrack,
              !isPlaying,
              !isAudioInterrupted,
              allowsAutomaticResume else {
            return false
        }
        let remainsMutedOnLocalOutput =
            enabled
            && volume <= minimumAudibleVolume
            && outputPortTypes.contains(where: supportsSystemVolumePause)
            && !outputPortTypes.contains(where: isExternalPlayback)
        return !remainsMutedOnLocalOutput
    }

    /// Returns true when an external listening route disappeared and playback
    /// must pause (wired headphones, AirPods / Bluetooth, AirPlay, car audio).
    static func shouldPauseAfterRouteLoss(
        wasPlaying: Bool,
        previousOutputPortTypes: [AVAudioSession.Port],
        currentOutputPortTypes: [AVAudioSession.Port]
    ) -> Bool {
        wasPlaying
            && previousOutputPortTypes.contains(where: isExternalPlayback)
            && !currentOutputPortTypes.contains(where: isExternalPlayback)
    }

    static func shouldResumeAfterRouteTransfer(
        pendingResume: Bool,
        playbackIntended: Bool,
        hasCurrentTrack: Bool,
        isPlaying: Bool,
        resumeBluetoothEnabled: Bool,
        currentOutputPortTypes: [AVAudioSession.Port]
    ) -> Bool {
        guard pendingResume,
              playbackIntended,
              hasCurrentTrack,
              !isPlaying,
              currentOutputPortTypes.contains(where: isExternalPlayback)
        else {
            return false
        }
        let usesBluetooth = currentOutputPortTypes.contains(where: isBluetooth)
        return !usesBluetooth || resumeBluetoothEnabled
    }

    private static func supportsSystemVolumePause(
        _ portType: AVAudioSession.Port
    ) -> Bool {
        portType == .builtInSpeaker || portType == .headphones
    }

    static func isBluetooth(_ portType: AVAudioSession.Port) -> Bool {
        [
            .bluetoothA2DP,
            .bluetoothHFP,
            .bluetoothLE
        ].contains(portType)
    }

    static func isExternalPlayback(_ portType: AVAudioSession.Port) -> Bool {
        isBluetooth(portType)
            || portType == .airPlay
            || portType == .headphones
            || portType == .lineOut
            || portType == .carAudio
            || portType == .HDMI
            || portType == .usbAudio
    }
}

enum AppVolumePolicy {
    static func shouldPauseAtZero(
        volume: Float,
        isPlaying: Bool
    ) -> Bool {
        isPlaying && volume <= AudioRoutePolicy.minimumAudibleVolume
    }

    static func shouldResumeAfterZeroPause(
        volume: Float,
        pausedForAppVolumeZero: Bool,
        playbackIntended: Bool,
        hasCurrentTrack: Bool,
        isPlaying: Bool,
        isAudioInterrupted: Bool = false,
        allowsAutomaticResume: Bool = true
    ) -> Bool {
        volume > AudioRoutePolicy.minimumAudibleVolume
            && pausedForAppVolumeZero
            && playbackIntended
            && hasCurrentTrack
            && !isPlaying
            && !isAudioInterrupted
            && allowsAutomaticResume
    }
}

enum AudioProcessingRoutePolicy {
    /// Remote AVPlayer handoff bypasses `MTAudioProcessingTap`. While EQ or
    /// spatial processing is active, keep decoding on the phone so the tap
    /// runs for every local session route — built-in speaker, wired/wireless
    /// headphones, Bluetooth A2DP, and CarKit / `.carAudio`. AirPlay remains
    /// available as an output route and receives the already-processed signal.
    static func allowsExternalPlayback(requiresAudioTap: Bool) -> Bool {
        !requiresAudioTap
    }
}

/// Whether `MTAudioProcessingTap` can be attached for a given source URL.
///
/// Apple documents that `AVAudioMix` / audio taps work on file-based and
/// progressive remote assets once tracks are available. HLS (`m3u8`) does
/// not expose tap-ready tracks — attaching a mix there is a common cause of
/// `AVPlayerItem` failures on CarKit / Bluetooth reconnects. Streaming
/// services that keep EQ on car routes either decode locally (file / PCM)
/// or skip in-app DSP for HLS handoff.
enum AudioProcessingAttachPolicy {
    static func supportsAudioTap(url: URL, isOffline: Bool) -> Bool {
        if isOffline { return true }
        return url.pathExtension.caseInsensitiveCompare("m3u8") != .orderedSame
    }

    /// After media-services reset (typical on car attach), suppress auto-skip
    /// briefly so a transient item failure retries the same track instead of
    /// jumping through the queue with error toasts.
    static let postResetAdvanceSuppression: TimeInterval = 8
}

enum PlaybackPreloadPolicy {
    static let maximumAge: TimeInterval = 5 * 60

    static func nextIndex(
        queueCount: Int,
        currentIndex: Int?,
        repeatMode: RepeatMode
    ) -> Int? {
        guard queueCount > 1,
              let currentIndex,
              (0..<queueCount).contains(currentIndex) else {
            return nil
        }
        if currentIndex + 1 < queueCount {
            return currentIndex + 1
        }
        return repeatMode == .all ? 0 : nil
    }

    static func isValid(
        trackID: String,
        url: URL,
        preparedTrackID: String,
        preparedURL: URL,
        preparedAt: Date,
        now: Date = Date()
    ) -> Bool {
        trackID == preparedTrackID
            && url == preparedURL
            && now.timeIntervalSince(preparedAt) < maximumAge
    }
}

enum ContinuationAdvancePolicy {
    static func shouldAdvance(
        requested: Bool,
        playbackIntended: Bool
    ) -> Bool {
        requested && playbackIntended
    }
}

enum AudioInterruptionPolicy {
    static func shouldResume(
        wasPlayingBeforeInterruption: Bool,
        playbackIntended: Bool,
        routeDisconnectPending: Bool,
        options: AVAudioSession.InterruptionOptions
    ) -> Bool {
        wasPlayingBeforeInterruption
            && playbackIntended
            && !routeDisconnectPending
            && options.contains(.shouldResume)
    }

    /// When interruption-on-route-disconnect ends before the route-change
    /// notification arrives, the current route may already be the built-in
    /// speaker while the previous route was headphones / BT / car.
    static func shouldTreatEndAsRouteDisconnect(
        previousOutputPortTypes: [AVAudioSession.Port],
        currentOutputPortTypes: [AVAudioSession.Port]
    ) -> Bool {
        AudioRoutePolicy.shouldPauseAfterRouteLoss(
            wasPlaying: true,
            previousOutputPortTypes: previousOutputPortTypes,
            currentOutputPortTypes: currentOutputPortTypes
        )
    }
}

/// Whether to restart playback after AVAudioSession media services die
/// (common when attaching CarKit / Bluetooth head units).
enum MediaServicesResetPolicy {
    static func shouldAutoplayAfterReset(
        playbackIntended: Bool,
        wasActivelyPlaying: Bool
    ) -> Bool {
        playbackIntended && wasActivelyPlaying
    }

    static func shouldSuppressAdvance(
        now: Date,
        suppressUntil: Date?
    ) -> Bool {
        guard let suppressUntil else { return false }
        return now < suppressUntil
    }
}

/// Same-track recovery before auto-skip on flaky networks / stale CDN URLs.
enum StreamFailureRetryPolicy {
    static let maximumSameTrackAttempts = 3
    static let maximumConnectivityAttempts = 8
    static let preferredForwardBufferDuration: TimeInterval = 30
    static let stallRecoveryThreshold: TimeInterval = 20
    static let baseRetryDelay: TimeInterval = 1.2

    static func retryDelay(forAttempt attempt: Int) -> TimeInterval {
        let clamped = max(attempt, 1)
        return min(baseRetryDelay * Double(clamped), 6)
    }

    static func isConnectivityFailure(_ error: Error?) -> Bool {
        if let apiError = error as? APIError {
            return apiError.isConnectivityFailure
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .dataNotAllowed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    /// Keep the current track while retries remain. Connectivity failures
    /// get a larger budget and never auto-advance the queue.
    static func shouldRetrySameTrack(
        attempts: Int,
        error: Error?
    ) -> Bool {
        if isConnectivityFailure(error) {
            return attempts <= maximumConnectivityAttempts
        }
        return attempts <= maximumSameTrackAttempts
    }

    static func shouldAdvance(
        attempts: Int,
        error: Error?,
        advanceOnPlaybackError: Bool
    ) -> Bool {
        guard advanceOnPlaybackError else { return false }
        if isConnectivityFailure(error) { return false }
        return attempts > maximumSameTrackAttempts
    }
}

@MainActor
final class AudioPlayer: ObservableObject {
    private final class PreloadedPlayback {
        let trackID: String
        let url: URL
        let asset: AVURLAsset
        let preparedAt: Date
        var isReady = false

        init(
            trackID: String,
            url: URL,
            asset: AVURLAsset,
            preparedAt: Date = Date()
        ) {
            self.trackID = trackID
            self.url = url
            self.asset = asset
            self.preparedAt = preparedAt
        }
    }

    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var queueSource: QueueSource?
    @Published private(set) var queueSeedTrackTitle: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    /// Exact transport clock. Not `@Published` — UI observes `progress` so
    /// catalog/library EnvironmentObject consumers are not invalidated at 2 Hz.
    private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var shuffleEnabled: Bool
    @Published private(set) var repeatMode: RepeatMode
    @Published private(set) var sleepTimerEndDate: Date?
    @Published var isPlayerPresented = false
    @Published var errorMessage: String?

    /// Scrubber / mini-player / lyrics clock (see `PlaybackProgressModel`).
    let progress = PlaybackProgressModel()

    private var player = AVPlayer()
    private let nowPlaying = NowPlayingController()
    private let equalizer = EqualizerDSP()
    private let historyStore: ListeningHistoryStore
    private var timeObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var remoteCommandTokens: [Any] = []
    private var sleepTask: Task<Void, Never>?
    private var streamUserAgent: String?
    private var itemStatusObservation: NSKeyValueObservation?
    private var outputVolumeObservation: NSKeyValueObservation?
    private var defaultContinuationProvider: (() async throws -> [Track])?
    private var activeContinuationProvider: (() async throws -> [Track])?
    private var streamRefreshProvider: ((Track) async throws -> Track)?
    private var offlineURLProvider: ((Track) -> URL?)?
    private var offlineInvalidationHandler: ((Track) -> Void)?
    private var offlinePlayedHandler: ((Track) -> Void)?
    private var playbackReadyHandler: ((Track, Bool) -> Void)?
    private var loadedOfflineTrackID: String?
    private var listenedTrackID: String?
    private var listenedPlaybackDuration: TimeInterval = 0
    private var lastListeningElapsedTime: TimeInterval?
    private var continuationTask: Task<Void, Never>?
    private var continuationPrefetchTask: Task<Void, Never>?
    private var advanceAfterContinuationPrefetch = false
    private var streamRefreshTask: Task<Void, Never>?
    private var lastPersistedSecond = -1
    private var playbackGeneration = 0
    private var continuationGeneration = 0
    private var streamRefreshGeneration = 0
    private var requiresStreamRefresh = false
    private var didAttemptStreamRefresh = false
    private var audioSessionConfigured = false
    private var restoredTrackIDs = Set<String>()
    private var loadedTrackID: String?
    private var resumeOnBluetoothConnection = true
    private var pauseAtMinimumVolume = true
    private var advanceOnPlaybackError = true
    private var lastNowPlayingSecond = -1
    private var playbackIntended = false
    private var pausedForMinimumVolume = false
    private var pausedForAppVolumeZero = false
    private var minimumVolumeResumeSuppressed = false
    private var wasPlayingBeforeInterruption = false
    private var isAudioInterrupted = false
    private var resumeAfterRouteTransfer = false
    private var routeDisconnectPending = false
    private var outputsAtInterruptionBegan: [AVAudioSession.Port] = []
    private var interruptionResumeTask: Task<Void, Never>?
    private var pendingRemoteCommand: RemoteCommandCoalescing.Command?
    private var remoteCommandFlushTask: Task<Void, Never>?
    private var lastPersistedQueueSignature = ""
    private var suppressAdvanceUntil: Date?
    private var streamRecoveryAttempts = 0
    private var streamRecoveryTask: Task<Void, Never>?
    private var stallStartedAt: Date?
    private var preloadedPlayback: PreloadedPlayback?
    private var preloadAssetTask: Task<Void, Never>?
    private var preloadGeneration = 0
    private var preloadStreamRefreshTask: Task<Void, Never>?
    private var preloadStreamRefreshTrackID: String?
    private var preloadStreamRefreshID: UUID?
    private var attemptedPreloadRefreshes = Set<String>()
    private var canPreloadPlayback: () -> Bool = { true }
    private var artworkPrefetchHandler: (([Track]) async -> Void)?
    private var artworkPrefetchTask: Task<Void, Never>?

    var currentTrack: Track? {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            return nil
        }
        return queue[currentIndex]
    }

    /// Human-readable label for what's currently queued, shown under
    /// "СЕЙЧАС ИГРАЕТ" in the full-screen player in place of a bare
    /// "N of M" position (that position now lives in the queue screen).
    var queueContextTitle: String {
        switch queueSource {
        case let .mix(title) where QueueSourceTitle.isUsable(title):
            return title
        case let .playlist(title) where QueueSourceTitle.isUsable(title):
            return title
        case let .album(title) where QueueSourceTitle.isUsable(title):
            return title
        case .history:
            return L10n.text("История прослушивания")
        default:
            if let seed = queueSeedTrackTitle,
               QueueSourceTitle.isUsable(seed) {
                return L10n.format("Микс по «%@»", seed)
            }
            return L10n.text("Ваша очередь")
        }
    }

    func presentPlayer() {
        guard !isPlayerPresented else { return }
        isPlayerPresented = true
    }

    func dismissPlayer() {
        guard isPlayerPresented else { return }
        isPlayerPresented = false
    }

    init(
        settings: AppSettings,
        historyStore: ListeningHistoryStore,
        userAgent: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.historyStore = historyStore
        self.streamUserAgent = userAgent
        resumeOnBluetoothConnection = settings.resumeOnBluetoothConnection
        pauseAtMinimumVolume = settings.pauseAtMinimumVolume
        // Playback level follows hardware / CarKit volume. Keep AVPlayer at
        // unity so the system volume slider is the only attenuation.
        advanceOnPlaybackError = settings.advanceOnPlaybackError
        shuffleEnabled = defaults.bool(forKey: "player.shuffle")
        repeatMode = RepeatMode(
            rawValue: defaults.string(forKey: "player.repeat") ?? ""
        ) ?? .off
        configurePlayerInstance()
        _ = configureAudioSession()
        configureRemoteCommands()
        observePlayer()
        Publishers.CombineLatest4(
            settings.$equalizerEnabled,
            settings.$equalizerGains,
            settings.$equalizerPreamp,
            settings.$loudnessNormalization
        )
        .combineLatest(
            Publishers.CombineLatest3(
                settings.$dynamicRangeCompression,
                settings.$spatialAudioEnabled,
                settings.$spatialAudioIntensity
            )
        )
            .sink { [weak self] equalizerSettings, effectsSettings in
                let (enabled, gains, preamp, loudness) = equalizerSettings
                let (drc, spatialAudio, spatialIntensity) = effectsSettings
                guard let self else { return }
                let requiredTap = self.equalizer.requiresAudioTap
                self.equalizer.update(
                    enabled: enabled,
                    gains: gains,
                    preamp: preamp,
                    loudnessNorm: loudness,
                    dynamicRangeCompression: drc,
                    spatialAudio: spatialAudio,
                    spatialIntensity: spatialIntensity
                )
                let requiresAudioTap = self.equalizer.requiresAudioTap
                self.player.allowsExternalPlayback = AudioProcessingRoutePolicy
                    .allowsExternalPlayback(
                        requiresAudioTap: requiresAudioTap
                    )
                if requiredTap != requiresAudioTap,
                   self.player.currentItem != nil {
                    self.reloadCurrentItemForAudioProcessing()
                }
            }
            .store(in: &cancellables)
        settings.$resumeOnBluetoothConnection
            .sink { [weak self] enabled in
                self?.resumeOnBluetoothConnection = enabled
            }
            .store(in: &cancellables)
        settings.$pauseAtMinimumVolume
            .sink { [weak self] enabled in
                guard let self else { return }
                self.pauseAtMinimumVolume = enabled
                self.handleOutputVolume(
                    AVAudioSession.sharedInstance().outputVolume
                )
            }
            .store(in: &cancellables)
        settings.$advanceOnPlaybackError
            .sink { [weak self] enabled in
                self?.advanceOnPlaybackError = enabled
            }
            .store(in: &cancellables)
        restorePlayback()
    }

    func configureContinuation(
        _ provider: @escaping () async throws -> [Track]
    ) {
        cancelContinuation()
        defaultContinuationProvider = provider
        activeContinuationProvider = provider
    }

    func configureStreamRefresh(
        _ provider: @escaping (Track) async throws -> Track
    ) {
        streamRefreshProvider = provider
    }

    func configurePreloading(
        isAllowed: @escaping () -> Bool,
        artworkPrefetch: @escaping ([Track]) async -> Void
    ) {
        canPreloadPlayback = isAllowed
        artworkPrefetchHandler = artworkPrefetch
        scheduleNeighborPreloads()
    }

    func cancelPreloading() {
        invalidatePreloadedPlayback()
        preloadStreamRefreshTask?.cancel()
        preloadStreamRefreshTask = nil
        preloadStreamRefreshTrackID = nil
        preloadStreamRefreshID = nil
        artworkPrefetchTask?.cancel()
        artworkPrefetchTask = nil
    }

    func resumePreloading() {
        scheduleNeighborPreloads()
    }

    func configureOfflinePlayback(
        lookup: @escaping (Track) -> URL?,
        invalidate: @escaping (Track) -> Void,
        markPlayed: @escaping (Track) -> Void
    ) {
        offlineURLProvider = lookup
        offlineInvalidationHandler = invalidate
        offlinePlayedHandler = markPlayed
    }

    func configurePlaybackReady(
        _ handler: @escaping (Track, Bool) -> Void
    ) {
        playbackReadyHandler = handler
    }

    func configureNetwork(userAgent: String?) {
        let cleaned = userAgent?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        streamUserAgent = cleaned?.isEmpty == false ? cleaned : nil
        invalidatePreloadedPlayback()
        scheduleNeighborPreloads()
    }

    func play(
        _ track: Track,
        in tracks: [Track],
        continuation: (() async throws -> [Track])? = nil,
        source: QueueSource? = nil
    ) {
        resumeAfterRouteTransfer = false
        routeDisconnectPending = false
        playbackIntended = true
        cancelContinuation()
        cancelStreamRefresh()
        cancelStreamRecovery()
        requiresStreamRefresh = false
        didAttemptStreamRefresh = false
        streamRecoveryAttempts = 0
        stallStartedAt = nil
        restoredTrackIDs.removeAll()
        attemptedPreloadRefreshes.removeAll()
        activeContinuationProvider =
            continuation ?? defaultContinuationProvider
        queueSource = source
        queueSeedTrackTitle = track.title
        let prepared = PlaybackQueueBuilder.normalized(
            selected: track,
            tracks: tracks
        )
        if shuffleEnabled {
            queue = [track]
                + prepared.filter { $0.id != track.id }.shuffled()
            currentIndex = 0
        } else {
            queue = prepared
            currentIndex = prepared.firstIndex {
                $0.id == track.id
            } ?? 0
        }
        resetProgressForTrackTransition()
        persistPlayback()
        loadCurrentAndPlay()
        startContinuationPrefetch()
    }

    func playNext(_ track: Track) {
        guard let currentIndex, let currentTrack else {
            play(track, in: [track])
            return
        }
        guard track.id != currentTrack.id else { return }
        cancelContinuation()
        queue.removeAll { $0.id == track.id }
        let adjustedCurrentIndex = queue.firstIndex {
            $0.id == currentTrack.id
        } ?? min(currentIndex, max(queue.count - 1, 0))
        self.currentIndex = adjustedCurrentIndex
        queue.insert(
            track,
            at: min(adjustedCurrentIndex + 1, queue.count)
        )
        persistPlayback()
        publishNowPlayingQueue()
        scheduleNeighborPreloads()
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index),
              let currentIndex,
              queue.indices.contains(currentIndex) else {
            return
        }
        cancelContinuation()
        let removesCurrentTrack = index == currentIndex
        let shouldResume = isPlaying
        let removedTrack = queue[index]
        queue.remove(at: index)
        restoredTrackIDs.remove(removedTrack.id)

        guard !queue.isEmpty else {
            stop()
            return
        }

        if index < currentIndex {
            self.currentIndex = currentIndex - 1
        } else if removesCurrentTrack {
            self.currentIndex = min(currentIndex, queue.count - 1)
        }

        if removesCurrentTrack {
            cancelStreamRefresh()
            requiresStreamRefresh = false
            didAttemptStreamRefresh = false
            resetProgressForTrackTransition()
            persistPlayback()
            loadCurrent(autoplay: shouldResume, startAt: 0)
        } else {
            persistPlayback()
            publishNowPlayingQueue()
            scheduleNeighborPreloads()
        }
    }

    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        resumeAfterRouteTransfer = false
        routeDisconnectPending = false
        playbackIntended = true
        cancelContinuation()
        cancelStreamRefresh()
        requiresStreamRefresh = false
        didAttemptStreamRefresh = false
        currentIndex = index
        resetProgressForTrackTransition()
        persistPlayback()
        loadCurrentAndPlay()
    }

    func toggleShuffle() {
        cancelContinuation()
        shuffleEnabled.toggle()
        defaults.set(shuffleEnabled, forKey: "player.shuffle")
        guard let currentTrack else { return }
        let remaining = queue.filter { $0.id != currentTrack.id }
        queue = [currentTrack]
            + (shuffleEnabled ? remaining.shuffled() : remaining)
        currentIndex = 0
        persistPlayback()
        publishNowPlayingQueue()
        scheduleNeighborPreloads()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        defaults.set(repeatMode.rawValue, forKey: "player.repeat")
        scheduleNeighborPreloads()
    }

    func scheduleSleepTimer(minutes: Int) {
        sleepTask?.cancel()
        let seconds = max(minutes, 1) * 60
        sleepTimerEndDate = Date().addingTimeInterval(
            TimeInterval(seconds)
        )
        sleepTask = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(seconds)
            )
            guard !Task.isCancelled else { return }
            self?.pause()
            self?.sleepTimerEndDate = nil
        }
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerEndDate = nil
    }

    func playPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        resume(
            preservingMinimumVolumePause: false,
            preservingAppVolumePause: false
        )
    }

    private func resume(
        preservingMinimumVolumePause: Bool,
        preservingAppVolumePause: Bool
    ) {
        if !preservingMinimumVolumePause {
            pausedForMinimumVolume = false
            minimumVolumeResumeSuppressed = false
        }
        if !preservingAppVolumePause {
            pausedForAppVolumeZero = false
        }
        playbackIntended = true
        interruptionResumeTask?.cancel()
        interruptionResumeTask = nil
        // While another app still owns the session, keep transfer intent so a
        // later interruption-end / route settle can resume. Clearing the flags
        // here used to drop CarKit / BT reconnect resumes permanently.
        guard !isAudioInterrupted else {
            resumeAfterRouteTransfer = true
            return
        }
        resumeAfterRouteTransfer = false
        routeDisconnectPending = false
        if requiresStreamRefresh {
            refreshCurrentStream(autoplay: true)
            return
        }
        guard player.currentItem != nil else {
            loadCurrentAndPlay()
            return
        }
        if duration > 0, elapsedTime >= duration - 0.25 {
            seek(to: 0)
        }
        guard activateAudioSession() else { return }
        pausedForMinimumVolume = false
        pausedForAppVolumeZero = false
        player.volume = 1
        player.play()
        isPlaying = true
        publishPlaybackState(force: true)
        handleOutputVolume(
            AVAudioSession.sharedInstance().outputVolume
        )
    }

    func pause() {
        pausedForMinimumVolume = false
        pausedForAppVolumeZero = false
        advanceAfterContinuationPrefetch = false
        minimumVolumeResumeSuppressed = false
        resumeAfterRouteTransfer = false
        routeDisconnectPending = false
        playbackIntended = false
        pausePreservingIntent()
    }

    /// Soft pause used while preparing a share export so AVFoundation media
    /// services are free for `AVAssetReader` without clearing the user's
    /// intent to keep listening afterwards.
    func pauseForShareExport() {
        pausePreservingIntent()
    }

    private func pausePreservingIntent() {
        player.pause()
        isPlaying = false
        publishPlaybackState(force: true)
    }

    func next() {
        guard let currentIndex, !queue.isEmpty else { return }
        let nextIndex = queue.index(after: currentIndex)
        if nextIndex >= queue.endIndex, repeatMode == .off {
            if continuationPrefetchTask != nil {
                advanceAfterContinuationPrefetch = true
                isBuffering = true
                return
            }
            startContinuationIfNeeded()
            return
        }
        cancelContinuation()
        cancelStreamRefresh()
        requiresStreamRefresh = false
        didAttemptStreamRefresh = false
        self.currentIndex = nextIndex < queue.endIndex ? nextIndex : 0
        resetProgressForTrackTransition()
        persistPlayback()
        loadCurrentAndPlay()
    }

    func previous() {
        if elapsedTime > 4 {
            seek(to: 0)
            return
        }
        guard let currentIndex, !queue.isEmpty else { return }
        cancelContinuation()
        cancelStreamRefresh()
        requiresStreamRefresh = false
        didAttemptStreamRefresh = false
        if currentIndex > 0 {
            self.currentIndex = currentIndex - 1
        } else {
            self.currentIndex = repeatMode == .all ? queue.count - 1 : 0
        }
        resetProgressForTrackTransition()
        persistPlayback()
        loadCurrentAndPlay()
    }

    func seek(to seconds: TimeInterval) {
        let upperBound = duration > 0 ? duration : seconds
        let targetSeconds = min(max(0, seconds), upperBound)
        lastListeningElapsedTime = targetSeconds
        let target = CMTime(
            seconds: targetSeconds,
            preferredTimescale: 600
        )
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        updateElapsedTime(targetSeconds, forceProgressPublish: true)
        persistPlayback()
        publishPlaybackState(force: true)
    }

    func stop() {
        pausedForMinimumVolume = false
        pausedForAppVolumeZero = false
        minimumVolumeResumeSuppressed = false
        resumeAfterRouteTransfer = false
        routeDisconnectPending = false
        playbackIntended = false
        playbackGeneration += 1
        dismissPlayer()
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerEndDate = nil
        cancelContinuation()
        cancelStreamRefresh()
        cancelPreloading()
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        queue = []
        currentIndex = nil
        queueSource = nil
        queueSeedTrackTitle = nil
        loadedTrackID = nil
        loadedOfflineTrackID = nil
        listenedTrackID = nil
        listenedPlaybackDuration = 0
        lastListeningElapsedTime = nil
        updateElapsedTime(0, forceProgressPublish: true)
        duration = 0
        isPlaying = false
        isBuffering = false
        requiresStreamRefresh = false
        didAttemptStreamRefresh = false
        restoredTrackIDs.removeAll()
        nowPlaying.clear()
        lastNowPlayingSecond = -1
        lastPersistedQueueSignature = ""
        defaults.removeObject(forKey: PlaybackSnapshot.key)
        defaults.removeObject(forKey: PlaybackSnapshot.elapsedKey)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func loadCurrentAndPlay() {
        pausedForMinimumVolume = false
        pausedForAppVolumeZero = false
        minimumVolumeResumeSuppressed = false
        playbackIntended = true
        if let track = currentTrack,
           restoredTrackIDs.contains(track.id),
           offlineURLProvider?(track) == nil {
            requiresStreamRefresh = true
            didAttemptStreamRefresh = false
            refreshCurrentStream(autoplay: true)
            return
        }
        loadCurrent(autoplay: true, startAt: 0)
    }

    private func loadCurrent(
        autoplay: Bool,
        startAt position: TimeInterval
    ) {
        guard let track = currentTrack else { return }
        let offlineURL = offlineURLProvider?(track)
        guard let url = offlineURL ?? track.streamURL else {
            if streamRefreshProvider != nil {
                streamRecoveryAttempts += 1
                if StreamFailureRetryPolicy.shouldRetrySameTrack(
                    attempts: streamRecoveryAttempts,
                    error: APIError.timedOut
                ) {
                    scheduleSameTrackRecovery(autoplay: autoplay)
                    return
                }
                if StreamFailureRetryPolicy.shouldAdvance(
                    attempts: streamRecoveryAttempts,
                    error: APIError.invalidResponse,
                    advanceOnPlaybackError: advanceOnPlaybackError
                ),
                   advancePastFailedTrackIfPossible() {
                    return
                }
            }
            loadedTrackID = track.id
            updateElapsedTime(0, forceProgressPublish: true)
            duration = track.duration
            errorMessage = L10n.text(
                "Для этого трека отсутствует доступный аудиопоток."
            )
            isPlaying = false
            nowPlaying.update(
                track: track,
                elapsedTime: 0,
                rate: 0,
                queueCount: queue.count,
                queueIndex: currentIndex ?? 0
            )
            return
        }
        errorMessage = nil

        playbackGeneration += 1
        let generation = playbackGeneration
        let isOffline = offlineURL != nil
        let item = takePreloadedPlayback(for: track, url: url)
            ?? makePlaybackItem(url: url, isOffline: isOffline)
        let wantsAudioTap = equalizer.requiresAudioTap
            && AudioProcessingAttachPolicy.supportsAudioTap(
                url: url,
                isOffline: isOffline
            )
        player.allowsExternalPlayback = AudioProcessingRoutePolicy
            .allowsExternalPlayback(requiresAudioTap: wantsAudioTap)
        // Defer mix attach until tracks exist (readyToPlay). Premature
        // AVAudioMix on remote progressive / empty-track assets fails the
        // item — especially after CarKit media-services resets.
        item.audioMix = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            Task { @MainActor in
                guard let self,
                      generation == self.playbackGeneration,
                      self.player.currentItem === item else {
                    return
                }
                switch item.status {
                case .readyToPlay:
                    self.isBuffering = false
                    self.streamRecoveryAttempts = 0
                    self.didAttemptStreamRefresh = false
                    self.stallStartedAt = nil
                    self.cancelStreamRecovery()
                    if wantsAudioTap {
                        self.attachAudioProcessing(to: item)
                    }
                    self.playbackReadyHandler?(track, isOffline)
                    self.scheduleNeighborPreloads()
                    if position > 0 {
                        self.seek(to: min(position, self.duration))
                    }
                case .failed:
                    self.isPlaying = false
                    self.isBuffering = false
                    self.handleItemFailure(item.error)
                case .unknown:
                    self.isBuffering = true
                @unknown default:
                    self.isBuffering = false
                }
            }
        }
        player.replaceCurrentItem(with: item)
        loadedTrackID = track.id
        loadedOfflineTrackID = isOffline ? track.id : nil
        updateElapsedTime(position, forceProgressPublish: true)
        duration = track.duration
        let shouldAutoplay = autoplay && activateAudioSession()
        if shouldAutoplay {
            pausedForMinimumVolume = false
            player.volume = 1
            player.play()
            isPlaying = true
            isBuffering = true
            handleOutputVolume(
                AVAudioSession.sharedInstance().outputVolume
            )
        } else {
            isPlaying = false
            isBuffering = false
        }
        nowPlaying.update(
            track: track,
            elapsedTime: position,
            rate: shouldAutoplay ? 1 : 0,
            queueCount: queue.count,
            queueIndex: currentIndex ?? 0
        )
        persistPlayback()
    }

    private func makePlaybackItem(
        url: URL,
        isOffline: Bool
    ) -> AVPlayerItem {
        let item = AVPlayerItem(
            asset: makePlaybackAsset(url: url, isOffline: isOffline)
        )
        item.preferredForwardBufferDuration =
            StreamFailureRetryPolicy.preferredForwardBufferDuration
        return item
    }

    private func makePlaybackAsset(
        url: URL,
        isOffline: Bool
    ) -> AVURLAsset {
        let asset: AVURLAsset
        if isOffline {
            asset = AVURLAsset(url: url)
        } else {
            var headers = [
                "Referer": "https://vk.com/",
                "Origin": "https://vk.com"
            ]
            if let streamUserAgent {
                headers["User-Agent"] = streamUserAgent
            }
            asset = AVURLAsset(
                url: url,
                options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
            )
        }
        return asset
    }

    private func attachAudioProcessing(to item: AVPlayerItem) {
        item.audioMix = nil
        guard equalizer.requiresAudioTap,
              let tap = equalizer.makeTap() else {
            return
        }
        // Bind the tap to a concrete audio track — required for remote
        // progressive URLs. Empty track lists (typical HLS) mean DSP cannot
        // run; leave the item unprocessed rather than failing playback.
        let audioTrack = item.tracks
            .compactMap(\.assetTrack)
            .first { $0.mediaType == .audio }
        guard let audioTrack else {
            player.allowsExternalPlayback = AudioProcessingRoutePolicy
                .allowsExternalPlayback(requiresAudioTap: false)
            return
        }
        let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }

    private func scheduleNeighborPreloads() {
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let remotePreloadingAllowed = canPreloadPlayback()
        if !lowPowerMode, remotePreloadingAllowed {
            prefetchNeighborArtwork()
        } else {
            artworkPrefetchTask?.cancel()
            artworkPrefetchTask = nil
        }
        guard !lowPowerMode,
              let nextIndex = PlaybackPreloadPolicy.nextIndex(
                queueCount: queue.count,
                currentIndex: currentIndex,
                repeatMode: repeatMode
              ),
              queue.indices.contains(nextIndex) else {
            invalidatePreloadedPlayback()
            return
        }
        let track = queue[nextIndex]
        if let refreshTrackID = preloadStreamRefreshTrackID,
           refreshTrackID != track.id {
            preloadStreamRefreshTask?.cancel()
            preloadStreamRefreshTask = nil
            preloadStreamRefreshTrackID = nil
            preloadStreamRefreshID = nil
        }
        let offlineURL = offlineURLProvider?(track)
        guard (offlineURL != nil || remotePreloadingAllowed),
              offlineURL != nil || !restoredTrackIDs.contains(track.id),
              let url = offlineURL ?? track.streamURL else {
            invalidatePreloadedPlayback()
            return
        }
        if let existing = preloadedPlayback,
           PlaybackPreloadPolicy.isValid(
            trackID: track.id,
            url: url,
            preparedTrackID: existing.trackID,
            preparedURL: existing.url,
            preparedAt: existing.preparedAt
           ) {
            return
        }

        invalidatePreloadedPlayback()
        let asset = makePlaybackAsset(
            url: url,
            isOffline: offlineURL != nil
        )
        let slot = PreloadedPlayback(
            trackID: track.id,
            url: url,
            asset: asset
        )
        preloadedPlayback = slot
        preloadGeneration += 1
        let generation = preloadGeneration
        preloadAssetTask = Task { [weak self] in
            do {
                let isPlayable = try await asset.load(.isPlayable)
                try Task.checkCancellation()
                guard let self,
                      generation == self.preloadGeneration,
                      self.preloadedPlayback === slot else {
                    return
                }
                self.preloadAssetTask = nil
                if isPlayable {
                    slot.isReady = true
                } else {
                    self.recoverPreloadAfterFailure(slot)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      generation == self.preloadGeneration,
                      self.preloadedPlayback === slot else {
                    return
                }
                self.preloadAssetTask = nil
                self.recoverPreloadAfterFailure(slot)
            }
        }
    }

    private func takePreloadedPlayback(
        for track: Track,
        url: URL
    ) -> AVPlayerItem? {
        guard let slot = preloadedPlayback,
              slot.isReady,
              PlaybackPreloadPolicy.isValid(
                trackID: track.id,
                url: url,
                preparedTrackID: slot.trackID,
                preparedURL: slot.url,
                preparedAt: slot.preparedAt
              ) else {
            if preloadedPlayback != nil {
                invalidatePreloadedPlayback()
            }
            return nil
        }
        preloadGeneration += 1
        preloadAssetTask?.cancel()
        preloadAssetTask = nil
        preloadedPlayback = nil
        let item = AVPlayerItem(asset: slot.asset)
        item.preferredForwardBufferDuration =
            StreamFailureRetryPolicy.preferredForwardBufferDuration
        return item
    }

    private func invalidatePreloadedPlayback() {
        preloadGeneration += 1
        preloadAssetTask?.cancel()
        preloadAssetTask = nil
        preloadedPlayback = nil
    }

    private func recoverPreloadAfterFailure(
        _ slot: PreloadedPlayback
    ) {
        let trackID = slot.trackID
        let failedURL = slot.url
        invalidatePreloadedPlayback()
        guard !failedURL.isFileURL,
              preloadStreamRefreshTask == nil,
              let provider = streamRefreshProvider,
              let track = queue.first(where: { $0.id == trackID }) else {
            return
        }
        let refreshKey = "\(trackID)#\(failedURL.absoluteString)"
        guard attemptedPreloadRefreshes.insert(refreshKey).inserted else {
            return
        }
        let refreshID = UUID()
        preloadStreamRefreshTrackID = trackID
        preloadStreamRefreshID = refreshID
        preloadStreamRefreshTask = Task { [weak self] in
            defer {
                if let self,
                   self.preloadStreamRefreshID == refreshID {
                    self.preloadStreamRefreshTask = nil
                    self.preloadStreamRefreshTrackID = nil
                    self.preloadStreamRefreshID = nil
                }
            }
            do {
                let refreshed = try await provider(track)
                try Task.checkCancellation()
                guard let self,
                      self.preloadStreamRefreshID == refreshID,
                      let nextIndex = PlaybackPreloadPolicy.nextIndex(
                        queueCount: self.queue.count,
                        currentIndex: self.currentIndex,
                        repeatMode: self.repeatMode
                      ),
                      self.queue.indices.contains(nextIndex),
                      self.queue[nextIndex].id == trackID else {
                    return
                }
                self.queue[nextIndex] = refreshed
                self.restoredTrackIDs.remove(trackID)
                self.persistPlayback()
                self.scheduleNeighborPreloads()
            } catch is CancellationError {
                self?.attemptedPreloadRefreshes.remove(refreshKey)
            } catch {}
        }
    }

    private func prefetchNeighborArtwork() {
        guard let currentIndex,
              queue.indices.contains(currentIndex) else {
            return
        }
        var neighbors: [Track] = []
        if currentIndex > 0 {
            neighbors.append(queue[currentIndex - 1])
        } else if repeatMode == .all, queue.count > 1 {
            neighbors.append(queue[queue.count - 1])
        }
        if let nextIndex = PlaybackPreloadPolicy.nextIndex(
            queueCount: queue.count,
            currentIndex: currentIndex,
            repeatMode: repeatMode
        ) {
            let next = queue[nextIndex]
            if !neighbors.contains(where: { $0.id == next.id }) {
                neighbors.append(next)
            }
        }
        artworkPrefetchTask?.cancel()
        guard let artworkPrefetchHandler, !neighbors.isEmpty else {
            artworkPrefetchTask = nil
            return
        }
        artworkPrefetchTask = Task {
            await artworkPrefetchHandler(neighbors)
        }
    }

    @discardableResult
    private func configureAudioSession() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio,
                options: []
            )
            if #available(iOS 17.0, *) {
                // Keep the system's expected media-app behavior when wired or
                // wireless headphones disappear: interrupt playback instead
                // of leaking audio through the device speaker.
                try? session.setPrefersInterruptionOnRouteDisconnect(true)
            }
            audioSessionConfigured = true
            return true
        } catch {
            audioSessionConfigured = false
            return false
        }
    }

    private func activateAudioSession() -> Bool {
        guard audioSessionConfigured || configureAudioSession() else {
            errorMessage = L10n.text(
                "Не удалось подготовить фоновое воспроизведение."
            )
            return false
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            return true
        } catch {
            errorMessage = L10n.text(
                "Не удалось включить звук. Закройте другое аудиоприложение "
                    + "и повторите попытку."
            )
            return false
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        remoteCommandTokens = [
            center.playCommand.addTarget { [weak self] _ in
                self?.enqueueRemoteCommand(.play)
                return .success
            },
            center.pauseCommand.addTarget { [weak self] _ in
                self?.enqueueRemoteCommand(.pause)
                return .success
            },
            center.togglePlayPauseCommand.addTarget { [weak self] _ in
                self?.enqueueRemoteCommand(.toggle)
                return .success
            },
            center.nextTrackCommand.addTarget { [weak self] _ in
                self?.enqueueRemoteCommand(.next)
                return .success
            },
            center.previousTrackCommand.addTarget { [weak self] _ in
                self?.enqueueRemoteCommand(.previous)
                return .success
            },
            center.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent
                else {
                    return .commandFailed
                }
                self?.enqueueRemoteCommand(.seek(event.positionTime))
                return .success
            }
        ]
    }

    /// Headphone / CarKit remotes often deliver pause+toggle in one burst.
    /// Coalesce on the main actor so the second command cannot undo the first.
    nonisolated private func enqueueRemoteCommand(
        _ command: RemoteCommandCoalescing.Command
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            pendingRemoteCommand = RemoteCommandCoalescing.merge(
                pending: pendingRemoteCommand,
                incoming: command
            )
            remoteCommandFlushTask?.cancel()
            remoteCommandFlushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard let self,
                      !Task.isCancelled,
                      let command = pendingRemoteCommand else {
                    return
                }
                pendingRemoteCommand = nil
                applyRemoteCommand(command)
            }
        }
    }

    private func applyRemoteCommand(
        _ command: RemoteCommandCoalescing.Command
    ) {
        switch command {
        case .play:
            resume()
        case .pause:
            pause()
        case .toggle:
            playPause()
        case .next:
            next()
        case .previous:
            previous()
        case let .seek(time):
            seek(to: time)
        }
    }

    private func configurePlayerInstance() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = 1
        player.allowsExternalPlayback = AudioProcessingRoutePolicy
            .allowsExternalPlayback(
                requiresAudioTap: equalizer.requiresAudioTap
            )
    }

    private func observePlayer() {
        installPeriodicTimeObserver()

        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      let finishedItem = notification.object as? AVPlayerItem,
                      finishedItem === self.player.currentItem else {
                    return
                }
                self.advanceAfterCompletion()
            }
        })
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[
                AVPlayerItemFailedToPlayToEndTimeErrorKey
            ] as? Error
            Task { @MainActor in
                guard let self,
                      let failedItem = notification.object as? AVPlayerItem,
                      failedItem === self.player.currentItem else {
                    return
                }
                self.isPlaying = false
                self.isBuffering = false
                self.handleItemFailure(error)
            }
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleInterruption(notification)
            }
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleRouteChange(notification)
            }
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleMediaServicesReset()
            }
        })
        outputVolumeObservation = AVAudioSession.sharedInstance().observe(
            \.outputVolume,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.handleOutputVolume(
                    AVAudioSession.sharedInstance().outputVolume
                )
            }
        }
    }

    private func installPeriodicTimeObserver() {
        let observedPlayer = player
        timeObserver = observedPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.player === observedPlayer,
                      self.loadedTrackID == self.currentTrack?.id,
                      self.player.currentItem != nil else {
                    return
                }
                let newElapsed = max(
                    0,
                    time.seconds.isFinite ? time.seconds : 0
                )
                self.updateElapsedTime(newElapsed)
                if let seconds = self.player.currentItem?.duration.seconds,
                   seconds.isFinite,
                   abs(self.duration - seconds) >= 0.25 {
                    self.duration = seconds
                }
                self.sampleListeningProgress()
                let buffering = self.isPlaying
                    && self.player.timeControlStatus
                        == .waitingToPlayAtSpecifiedRate
                if buffering {
                    if self.stallStartedAt == nil {
                        self.stallStartedAt = Date()
                    } else if let started = self.stallStartedAt,
                              Date().timeIntervalSince(started)
                                >= StreamFailureRetryPolicy
                                .stallRecoveryThreshold {
                        self.stallStartedAt = nil
                        self.recoverFromExtendedStall()
                    }
                } else {
                    self.stallStartedAt = nil
                }
                if self.isBuffering != buffering {
                    self.isBuffering = buffering
                }
                self.publishPlaybackState()
                let wholeSecond = Int(self.elapsedTime)
                if wholeSecond > 0,
                   wholeSecond % 15 == 0,
                   wholeSecond != self.lastPersistedSecond {
                    self.lastPersistedSecond = wholeSecond
                    self.persistPlayback()
                }
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[
            AVAudioSessionInterruptionTypeKey
        ] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            return
        }
        switch type {
        case .began:
            interruptionResumeTask?.cancel()
            interruptionResumeTask = nil
            isAudioInterrupted = true
            outputsAtInterruptionBegan = AVAudioSession.sharedInstance()
                .currentRoute.outputs.map(\.portType)
            wasPlayingBeforeInterruption = playbackIntended && isPlaying
            pausePreservingIntent()
        case .ended:
            isAudioInterrupted = false
            let currentOutputs = AVAudioSession.sharedInstance()
                .currentRoute.outputs.map(\.portType)
            if AudioInterruptionPolicy.shouldTreatEndAsRouteDisconnect(
                previousOutputPortTypes: outputsAtInterruptionBegan,
                currentOutputPortTypes: currentOutputs
            ) {
                routeDisconnectPending = true
                resumeAfterRouteTransfer =
                    wasPlayingBeforeInterruption && playbackIntended
                wasPlayingBeforeInterruption = false
                outputsAtInterruptionBegan = []
                handleOutputVolume(AVAudioSession.sharedInstance().outputVolume)
                return
            }
            let rawOptions = notification.userInfo?[
                AVAudioSessionInterruptionOptionKey
            ] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(
                rawValue: rawOptions
            )
            let shouldResume = AudioInterruptionPolicy.shouldResume(
                wasPlayingBeforeInterruption: wasPlayingBeforeInterruption,
                playbackIntended: playbackIntended,
                routeDisconnectPending: routeDisconnectPending,
                options: options
            )
            wasPlayingBeforeInterruption = false
            outputsAtInterruptionBegan = []
            if shouldResume {
                scheduleInterruptionResume()
            } else if resumeAfterRouteTransfer,
                      playbackIntended,
                      !routeDisconnectPending {
                scheduleInterruptionResume()
            }
            handleOutputVolume(AVAudioSession.sharedInstance().outputVolume)
        @unknown default:
            break
        }
    }

    /// Brief delay so a trailing `.oldDeviceUnavailable` can set
    /// `routeDisconnectPending` before we reactivate into the speaker.
    private func scheduleInterruptionResume() {
        interruptionResumeTask?.cancel()
        interruptionResumeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            guard !isAudioInterrupted,
                  playbackIntended,
                  !routeDisconnectPending else {
                return
            }
            resume()
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[
            AVAudioSessionRouteChangeReasonKey
        ] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(
                rawValue: rawReason
              ) else {
            return
        }
        var allowsMinimumVolumeResume = true
        switch reason {
        case .oldDeviceUnavailable:
            interruptionResumeTask?.cancel()
            interruptionResumeTask = nil
            let previousRoute = notification.userInfo?[
                AVAudioSessionRouteChangePreviousRouteKey
            ] as? AVAudioSessionRouteDescription
            let previousOutputs = previousRoute?.outputs.map(\.portType) ?? []
            let currentOutputs = AVAudioSession.sharedInstance()
                .currentRoute.outputs.map(\.portType)
            let playbackWasActive = isPlaying || wasPlayingBeforeInterruption
            if AudioRoutePolicy.shouldPauseAfterRouteLoss(
                wasPlaying: playbackWasActive,
                previousOutputPortTypes: previousOutputs,
                currentOutputPortTypes: currentOutputs
            ) {
                routeDisconnectPending = true
                resumeAfterRouteTransfer = playbackIntended
                    && playbackWasActive
                pausePreservingIntent()
            }
        case .newDeviceAvailable:
            let pendingResume = resumeAfterRouteTransfer
            resumeAfterRouteTransfer = false
            let currentOutputs = AVAudioSession.sharedInstance()
                .currentRoute.outputs.map(\.portType)
            if currentOutputs.contains(where: AudioRoutePolicy.isBluetooth),
               !resumeOnBluetoothConnection {
                allowsMinimumVolumeResume = false
                minimumVolumeResumeSuppressed = true
            }
            if AudioRoutePolicy.shouldResumeAfterRouteTransfer(
                pendingResume: pendingResume,
                playbackIntended: playbackIntended,
                hasCurrentTrack: currentTrack != nil,
                isPlaying: isPlaying,
                resumeBluetoothEnabled: resumeOnBluetoothConnection,
                currentOutputPortTypes: currentOutputs
            ) {
                routeDisconnectPending = false
                _ = activateAudioSession()
                resume()
            } else if currentOutputs.contains(
                where: AudioRoutePolicy.isExternalPlayback
            ) {
                // Settled on an external route — speaker-leak risk is gone,
                // so do not leave `routeDisconnectPending` stuck forever
                // (it would block later call-end auto-resume).
                routeDisconnectPending = false
                _ = activateAudioSession()
            }
        default:
            break
        }
        handleOutputVolume(
            AVAudioSession.sharedInstance().outputVolume,
            allowsAutomaticResume: allowsMinimumVolumeResume
        )
    }

    private func handleMediaServicesReset() {
        let wasActivelyPlaying = isPlaying
            || wasPlayingBeforeInterruption
            || resumeAfterRouteTransfer
        let shouldAutoplay = MediaServicesResetPolicy.shouldAutoplayAfterReset(
            playbackIntended: playbackIntended,
            wasActivelyPlaying: wasActivelyPlaying
        )
        let position = elapsedTime
        let keepIntent = playbackIntended || wasActivelyPlaying
        suppressAdvanceUntil = Date().addingTimeInterval(
            AudioProcessingAttachPolicy.postResetAdvanceSuppression
        )

        interruptionResumeTask?.cancel()
        interruptionResumeTask = nil
        pausedForMinimumVolume = false
        pausedForAppVolumeZero = false
        minimumVolumeResumeSuppressed = false
        isAudioInterrupted = false
        wasPlayingBeforeInterruption = false
        resumeAfterRouteTransfer = false
        routeDisconnectPending = false
        outputsAtInterruptionBegan = []
        isPlaying = false
        isBuffering = false
        playbackIntended = keepIntent
        publishPlaybackState(force: true)

        cancelContinuation()
        cancelStreamRefresh()
        cancelPreloading()
        playbackGeneration += 1
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil

        let orphanedPlayer = player
        if let timeObserver {
            orphanedPlayer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        orphanedPlayer.pause()
        orphanedPlayer.replaceCurrentItem(with: nil)

        player = AVPlayer()
        configurePlayerInstance()
        installPeriodicTimeObserver()
        loadedTrackID = nil
        loadedOfflineTrackID = nil

        audioSessionConfigured = false
        let audioSessionRestored = configureAudioSession()
        guard currentTrack != nil else { return }
        loadCurrent(autoplay: shouldAutoplay, startAt: position)
        if !audioSessionRestored {
            errorMessage = L10n.text(
                "Не удалось восстановить аудиовыход."
            )
        }
    }

    private func reloadCurrentItemForAudioProcessing() {
        guard currentTrack != nil else { return }
        let shouldResume = isPlaying
        let position = elapsedTime
        loadCurrent(autoplay: shouldResume, startAt: position)
    }

    private func handleOutputVolume(
        _ volume: Float,
        allowsAutomaticResume: Bool = true
    ) {
        let outputPortTypes = AVAudioSession.sharedInstance()
            .currentRoute.outputs.map(\.portType)
        if AudioRoutePolicy.shouldPause(
            volume: volume,
            enabled: pauseAtMinimumVolume,
            isPlaying: isPlaying,
            outputPortTypes: outputPortTypes
        ) {
            pausedForMinimumVolume = true
            minimumVolumeResumeSuppressed = false
            pausePreservingIntent()
            return
        }
        guard AudioRoutePolicy.shouldResumeAfterMinimumVolumePause(
            volume: volume,
            enabled: pauseAtMinimumVolume,
            pausedForMinimumVolume: pausedForMinimumVolume,
            playbackIntended: playbackIntended,
            hasCurrentTrack: currentTrack != nil,
            isPlaying: isPlaying,
            outputPortTypes: outputPortTypes,
            isAudioInterrupted: isAudioInterrupted,
            allowsAutomaticResume: allowsAutomaticResume
                && !minimumVolumeResumeSuppressed
        ) else { return }
        resume(
            preservingMinimumVolumePause: true,
            preservingAppVolumePause: false
        )
    }

    private func advanceAfterCompletion() {
        if repeatMode == .one {
            seek(to: 0)
            resume()
        } else {
            next()
        }
    }

    private func publishPlaybackState(force: Bool = false) {
        let second = Int(elapsedTime.rounded(.down))
        guard force || second != lastNowPlayingSecond else { return }
        lastNowPlayingSecond = second
        nowPlaying.updatePlayback(
            elapsedTime: elapsedTime,
            rate: isPlaying ? 1 : 0
        )
    }

    private func publishNowPlayingQueue() {
        nowPlaying.updateQueue(
            count: queue.count,
            index: currentIndex ?? 0
        )
    }

    private func handleItemFailure(_ error: Error?) {
        publishPlaybackState(force: true)
        if let track = currentTrack,
           loadedOfflineTrackID == track.id {
            loadedOfflineTrackID = nil
            offlineInvalidationHandler?(track)
            didAttemptStreamRefresh = false
            if track.streamURL != nil {
                loadCurrent(autoplay: true, startAt: elapsedTime)
            } else if streamRefreshProvider != nil {
                refreshCurrentStream(autoplay: true)
            }
            return
        }
        // After CarKit media-services reset, prefer one same-track reload
        // over cascading through the queue with skip-on-error.
        if MediaServicesResetPolicy.shouldSuppressAdvance(
            now: Date(),
            suppressUntil: suppressAdvanceUntil
        ),
           currentTrack != nil {
            suppressAdvanceUntil = nil
            didAttemptStreamRefresh = false
            streamRecoveryAttempts = 0
            loadCurrent(autoplay: playbackIntended, startAt: elapsedTime)
            return
        }

        streamRecoveryAttempts += 1
        if StreamFailureRetryPolicy.shouldRetrySameTrack(
            attempts: streamRecoveryAttempts,
            error: error
        ) {
            scheduleSameTrackRecovery(autoplay: true)
            return
        }

        if StreamFailureRetryPolicy.shouldAdvance(
            attempts: streamRecoveryAttempts,
            error: error,
            advanceOnPlaybackError: advanceOnPlaybackError
        ),
           advancePastFailedTrackIfPossible() {
            return
        }

        let urlError = error as? URLError
        errorMessage = L10n.text(
            StreamFailureRetryPolicy.isConnectivityFailure(error)
                ? "Слабое соединение. Плеер продолжает пробовать этот трек."
                : urlError?.code == .cancelled
                    ? "Аудиопоток был прерван. Повторите воспроизведение."
                    : "Не удалось воспроизвести этот трек. "
                        + "Проверьте подключение и попробуйте ещё раз."
        )
        isBuffering = StreamFailureRetryPolicy.isConnectivityFailure(error)
        Haptics.error()
    }

    private func scheduleSameTrackRecovery(autoplay: Bool) {
        cancelStreamRecovery()
        isPlaying = false
        isBuffering = true
        errorMessage = nil
        let position = elapsedTime
        let delay = StreamFailureRetryPolicy.retryDelay(
            forAttempt: streamRecoveryAttempts
        )
        let generation = playbackGeneration
        let trackID = currentTrack?.id
        streamRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self,
                  !Task.isCancelled,
                  generation == self.playbackGeneration,
                  self.currentTrack?.id == trackID else {
                return
            }
            self.didAttemptStreamRefresh = false
            if self.streamRefreshProvider != nil {
                self.refreshCurrentStream(autoplay: autoplay)
            } else {
                self.loadCurrent(autoplay: autoplay, startAt: position)
            }
        }
    }

    private func recoverFromExtendedStall() {
        guard playbackIntended,
              currentTrack != nil,
              streamRecoveryTask == nil,
              streamRefreshTask == nil else {
            return
        }
        streamRecoveryAttempts += 1
        guard StreamFailureRetryPolicy.shouldRetrySameTrack(
            attempts: streamRecoveryAttempts,
            error: URLError(.timedOut)
        ) else {
            return
        }
        scheduleSameTrackRecovery(autoplay: true)
    }

    @discardableResult
    private func advancePastFailedTrackIfPossible() -> Bool {
        guard advanceOnPlaybackError,
              let currentIndex,
              !queue.isEmpty else {
            return false
        }
        if MediaServicesResetPolicy.shouldSuppressAdvance(
            now: Date(),
            suppressUntil: suppressAdvanceUntil
        ) {
            return false
        }

        if currentIndex + 1 < queue.count {
            cancelContinuation()
            cancelStreamRefresh()
            cancelStreamRecovery()
            requiresStreamRefresh = false
            didAttemptStreamRefresh = false
            streamRecoveryAttempts = 0
            stallStartedAt = nil
            self.currentIndex = currentIndex + 1
            errorMessage = nil
            resetProgressForTrackTransition()
            persistPlayback()
            loadCurrentAndPlay()
            return true
        }

        if activeContinuationProvider != nil {
            errorMessage = nil
            startContinuationIfNeeded()
            return true
        }

        guard repeatMode == .all, queue.count > 1 else {
            return false
        }
        cancelContinuation()
        cancelStreamRefresh()
        cancelStreamRecovery()
        requiresStreamRefresh = false
        didAttemptStreamRefresh = false
        streamRecoveryAttempts = 0
        stallStartedAt = nil
        self.currentIndex = 0
        errorMessage = nil
        resetProgressForTrackTransition()
        persistPlayback()
        loadCurrentAndPlay()
        return true
    }

    private func refreshCurrentStream(autoplay: Bool) {
        guard streamRefreshTask == nil,
              let provider = streamRefreshProvider,
              let index = currentIndex,
              queue.indices.contains(index) else {
            return
        }
        let track = queue[index]
        let position = elapsedTime
        didAttemptStreamRefresh = true
        isBuffering = true
        streamRefreshGeneration += 1
        let generation = streamRefreshGeneration
        streamRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let refreshed = try await provider(track)
                guard !Task.isCancelled,
                      generation == self.streamRefreshGeneration,
                      self.currentIndex == index,
                      self.currentTrack?.id == track.id else {
                    return
                }
                self.queue[index] = refreshed
                self.restoredTrackIDs.remove(track.id)
                self.requiresStreamRefresh = false
                self.streamRefreshTask = nil
                self.loadCurrent(
                    autoplay: autoplay,
                    startAt: position
                )
            } catch is CancellationError {
                guard generation == self.streamRefreshGeneration else {
                    return
                }
                self.streamRefreshTask = nil
                self.isBuffering = false
            } catch {
                guard generation == self.streamRefreshGeneration else {
                    return
                }
                self.streamRefreshTask = nil
                // Re-enter the same-track retry budget instead of skipping
                // after the first flaky refresh.
                self.handleItemFailure(error)
            }
        }
    }

    private func cancelStreamRecovery() {
        streamRecoveryTask?.cancel()
        streamRecoveryTask = nil
    }

    private func cancelContinuation() {
        if advanceAfterContinuationPrefetch {
            isBuffering = false
        }
        continuationGeneration += 1
        continuationTask?.cancel()
        continuationTask = nil
        continuationPrefetchTask?.cancel()
        continuationPrefetchTask = nil
        advanceAfterContinuationPrefetch = false
    }

    private func cancelStreamRefresh() {
        streamRefreshGeneration += 1
        streamRefreshTask?.cancel()
        streamRefreshTask = nil
        cancelStreamRecovery()
    }

    private func startContinuationIfNeeded() {
        guard continuationTask == nil else { return }
        continuationGeneration += 1
        let generation = continuationGeneration
        let sourceIndex = currentIndex
        continuationTask = Task { [weak self] in
            guard let self else { return }
            await self.continueQueueIfPossible(
                generation: generation,
                sourceIndex: sourceIndex
            )
            guard generation == self.continuationGeneration else {
                return
            }
            self.continuationTask = nil
        }
    }

    private func startContinuationPrefetch() {
        guard continuationPrefetchTask == nil,
              let provider = activeContinuationProvider else {
            return
        }
        let generation = continuationGeneration
        let sourceIndex = currentIndex
        continuationPrefetchTask = Task { [weak self] in
            guard let self else { return }
            var additions: [Track] = []
            do {
                for attempt in 0..<3 {
                    let proposed = try await self.continuationTracks(
                        from: provider
                    )
                    guard !Task.isCancelled,
                          generation == self.continuationGeneration,
                          self.currentIndex == sourceIndex else {
                        return
                    }
                    additions = PlaybackQueueBuilder.uniqueAdditions(
                        existing: self.queue,
                        candidates: proposed
                    )
                    if !additions.isEmpty { break }
                    if attempt < 2 {
                        try await Task.sleep(for: .milliseconds(180))
                    }
                }
            } catch {
                additions = []
            }
            guard !Task.isCancelled,
                  generation == self.continuationGeneration,
                  self.currentIndex == sourceIndex else {
                return
            }
            self.continuationPrefetchTask = nil
            let shouldAdvance = ContinuationAdvancePolicy.shouldAdvance(
                requested: self.advanceAfterContinuationPrefetch,
                playbackIntended: self.playbackIntended
            )
            self.advanceAfterContinuationPrefetch = false
            if !shouldAdvance {
                self.isBuffering = false
            }
            if !additions.isEmpty {
                self.queue.append(contentsOf: additions)
                self.persistPlayback()
                self.publishNowPlayingQueue()
                self.scheduleNeighborPreloads()
                if shouldAdvance,
                   let sourceIndex,
                   self.queue.indices.contains(sourceIndex + 1) {
                    self.currentIndex = sourceIndex + 1
                    self.resetProgressForTrackTransition()
                    self.persistPlayback()
                    self.loadCurrentAndPlay()
                }
            } else if shouldAdvance {
                self.startContinuationIfNeeded()
            }
        }
    }

    private func continueQueueIfPossible(
        generation: Int,
        sourceIndex: Int?
    ) async {
        guard let continuationProvider = activeContinuationProvider else {
            pause()
            return
        }
        do {
            var additions: [Track] = []
            for attempt in 0..<3 {
                let proposed = try await continuationTracks(
                    from: continuationProvider
                )
                guard !Task.isCancelled,
                      generation == continuationGeneration,
                      currentIndex == sourceIndex else {
                    return
                }
                additions = PlaybackQueueBuilder.uniqueAdditions(
                    existing: queue,
                    candidates: proposed
                )
                if !additions.isEmpty {
                    break
                }
                if attempt < 2 {
                    try await Task.sleep(for: .milliseconds(180))
                }
            }
            guard !additions.isEmpty else {
                isBuffering = false
                pause()
                return
            }
            queue.append(contentsOf: additions)
            if let currentIndex {
                self.currentIndex = currentIndex + 1
            }
            resetProgressForTrackTransition()
            persistPlayback()
            loadCurrentAndPlay()
        } catch is CancellationError {
            return
        } catch let error as APIError
            where error == .unauthorized || error.isConnectivityFailure {
            isBuffering = false
            pause()
            return
        } catch {
            isBuffering = false
            pause()
            return
        }
    }

    private func continuationTracks(
        from provider: () async throws -> [Track]
    ) async throws -> [Track] {
        do {
            return try await provider()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized {
            // Authorization recovery belongs to AppEnvironment. Repeating it
            // here would start a second cookie exchange after the centralized
            // recovery has already been exhausted.
            throw error
        } catch {
            try await Task.sleep(for: .milliseconds(350))
            try Task.checkCancellation()
            return try await provider()
        }
    }

    private func updateElapsedTime(
        _ value: TimeInterval,
        forceProgressPublish: Bool = false
    ) {
        let sanitized = max(value, 0)
        elapsedTime = sanitized
        if forceProgressPublish {
            progress.reset(to: sanitized)
        } else {
            progress.update(sanitized)
        }
    }

    private func persistPlayback(forceFullSnapshot: Bool = false) {
        guard !queue.isEmpty, let currentIndex else { return }
        defaults.set(elapsedTime, forKey: PlaybackSnapshot.elapsedKey)
        let signature = queue.map(\.id).joined(separator: "|")
            + "#\(currentIndex)"
        guard forceFullSnapshot || signature != lastPersistedQueueSignature
        else {
            return
        }
        let snapshot = PlaybackSnapshot(
            queue: queue,
            currentIndex: currentIndex,
            elapsedTime: elapsedTime
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: PlaybackSnapshot.key)
        lastPersistedQueueSignature = signature
    }

    private func resetProgressForTrackTransition() {
        loadedTrackID = nil
        loadedOfflineTrackID = nil
        updateElapsedTime(0, forceProgressPublish: true)
        duration = currentTrack?.duration ?? 0
        lastPersistedSecond = -1
        lastNowPlayingSecond = -1
        listenedTrackID = nil
        listenedPlaybackDuration = 0
        lastListeningElapsedTime = nil
    }

    private func sampleListeningProgress() {
        let sample = elapsedTime
        defer { lastListeningElapsedTime = sample }
        guard isPlaying,
              player.timeControlStatus == .playing,
              let previous = lastListeningElapsedTime else {
            return
        }
        let delta = sample - previous
        guard delta > 0, delta <= 1.5 else { return }
        listenedPlaybackDuration += delta
        markCurrentTrackListenedIfNeeded()
    }

    private func markCurrentTrackListenedIfNeeded() {
        guard let track = currentTrack,
              ListeningProgressPolicy.shouldMarkListened(
                accumulatedPlayback: listenedPlaybackDuration,
                duration: duration,
                alreadyMarked: listenedTrackID == track.id
              ) else {
            return
        }
        listenedTrackID = track.id
        historyStore.record(track)
        if loadedOfflineTrackID == track.id {
            offlinePlayedHandler?(track)
        }
    }

    private func restorePlayback() {
        guard let data = defaults.data(forKey: PlaybackSnapshot.key),
              let snapshot = try? JSONDecoder().decode(
                PlaybackSnapshot.self,
                from: data
              ),
              snapshot.queue.indices.contains(snapshot.currentIndex) else {
            return
        }
        queue = snapshot.queue
        restoredTrackIDs = Set(snapshot.queue.map(\.id))
        currentIndex = snapshot.currentIndex
        loadedTrackID = nil
        duration = currentTrack?.duration ?? 0
        let storedElapsed = defaults.object(
            forKey: PlaybackSnapshot.elapsedKey
        ) as? TimeInterval
        let restoredPosition = max(storedElapsed ?? snapshot.elapsedTime, 0)
        updateElapsedTime(
            duration > 0 ? min(restoredPosition, duration) : restoredPosition,
            forceProgressPublish: true
        )
        lastPersistedQueueSignature = snapshot.queue.map(\.id).joined(separator: "|")
            + "#\(snapshot.currentIndex)"
        requiresStreamRefresh = true
        if let track = currentTrack {
            nowPlaying.update(
                track: track,
                elapsedTime: elapsedTime,
                rate: 0,
                queueCount: queue.count,
                queueIndex: currentIndex ?? 0
            )
        }
    }
}

private struct PlaybackSnapshot: Codable {
    static let key = "player.playback.snapshot.v1"
    static let elapsedKey = "player.playback.elapsed.v1"

    let queue: [Track]
    let currentIndex: Int
    let elapsedTime: TimeInterval
}
