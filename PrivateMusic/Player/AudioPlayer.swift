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
}

@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var shuffleEnabled: Bool
    @Published private(set) var repeatMode: RepeatMode
    @Published private(set) var sleepTimerEndDate: Date?
    @Published var isPlayerPresented = false
    @Published var errorMessage: String?

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
    private var continuationTask: Task<Void, Never>?
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
    private var wasPlayingBeforeInterruption = false
    private var resumeAfterRouteTransfer = false
    private var routeDisconnectPending = false

    var currentTrack: Track? {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            return nil
        }
        return queue[currentIndex]
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
                if requiredTap != self.equalizer.requiresAudioTap,
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
    }

    func play(
        _ track: Track,
        in tracks: [Track],
        continuation: (() async throws -> [Track])? = nil
    ) {
        resumeAfterRouteTransfer = false
        routeDisconnectPending = false
        playbackIntended = true
        cancelContinuation()
        cancelStreamRefresh()
        requiresStreamRefresh = false
        didAttemptStreamRefresh = false
        restoredTrackIDs.removeAll()
        activeContinuationProvider =
            continuation ?? defaultContinuationProvider
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
    }

    func playNext(_ track: Track) {
        guard let currentIndex else {
            play(track, in: [track])
            return
        }
        cancelContinuation()
        queue.removeAll { $0.id == track.id }
        queue.insert(track, at: min(currentIndex + 1, queue.count))
        persistPlayback()
        publishNowPlayingQueue()
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
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        defaults.set(repeatMode.rawValue, forKey: "player.repeat")
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
        resumeAfterRouteTransfer = false
        routeDisconnectPending = false
        playbackIntended = true
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
        player.play()
        isPlaying = true
        publishPlaybackState(force: true)
        handleOutputVolume(
            AVAudioSession.sharedInstance().outputVolume
        )
    }

    func pause() {
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
        let target = CMTime(
            seconds: targetSeconds,
            preferredTimescale: 600
        )
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        elapsedTime = targetSeconds
        persistPlayback()
        publishPlaybackState(force: true)
    }

    func stop() {
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
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        queue = []
        currentIndex = nil
        loadedTrackID = nil
        loadedOfflineTrackID = nil
        elapsedTime = 0
        duration = 0
        isPlaying = false
        isBuffering = false
        requiresStreamRefresh = false
        didAttemptStreamRefresh = false
        restoredTrackIDs.removeAll()
        nowPlaying.clear()
        lastNowPlayingSecond = -1
        defaults.removeObject(forKey: PlaybackSnapshot.key)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func loadCurrentAndPlay() {
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
                if !didAttemptStreamRefresh {
                    requiresStreamRefresh = true
                    refreshCurrentStream(autoplay: autoplay)
                    return
                }
                if advancePastFailedTrackIfPossible() {
                    return
                }
            }
            loadedTrackID = track.id
            elapsedTime = 0
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
        let item = AVPlayerItem(asset: asset)
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
                    if isOffline {
                        self.offlinePlayedHandler?(track)
                    }
                    self.playbackReadyHandler?(track, isOffline)
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
        if let tap = equalizer.makeTap() {
            let parameters = AVMutableAudioMixInputParameters()
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
        }
        item.preferredForwardBufferDuration = 8
        player.replaceCurrentItem(with: item)
        loadedTrackID = track.id
        loadedOfflineTrackID = isOffline ? track.id : nil
        elapsedTime = position
        duration = track.duration
        let shouldAutoplay = autoplay && activateAudioSession()
        if shouldAutoplay {
            player.play()
            isPlaying = true
            isBuffering = true
            historyStore.record(track)
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
                Task { @MainActor in self?.resume() }
                return .success
            },
            center.pauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.pause() }
                return .success
            },
            center.togglePlayPauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.playPause() }
                return .success
            },
            center.nextTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.next() }
                return .success
            },
            center.previousTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.previous() }
                return .success
            },
            center.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent
                else {
                    return .commandFailed
                }
                Task { @MainActor in self?.seek(to: event.positionTime) }
                return .success
            }
        ]
    }

    private func configurePlayerInstance() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
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
        ) { [weak self] session, change in
            let volume = change.newValue ?? session.outputVolume
            Task { @MainActor in
                self?.handleOutputVolume(volume)
            }
        }
    }

    private func installPeriodicTimeObserver() {
        let observedPlayer = player
        timeObserver = observedPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self,
                      self.player === observedPlayer,
                      self.loadedTrackID == self.currentTrack?.id,
                      self.player.currentItem != nil else {
                    return
                }
                self.elapsedTime = max(
                    0,
                    time.seconds.isFinite ? time.seconds : 0
                )
                if let seconds = self.player.currentItem?.duration.seconds,
                   seconds.isFinite {
                    self.duration = seconds
                }
                self.isBuffering = self.isPlaying
                    && self.player.timeControlStatus
                        == .waitingToPlayAtSpecifiedRate
                self.publishPlaybackState()
                let wholeSecond = Int(self.elapsedTime)
                if wholeSecond > 0,
                   wholeSecond % 5 == 0,
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
            wasPlayingBeforeInterruption = playbackIntended && isPlaying
            pausePreservingIntent()
        case .ended:
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
            if shouldResume {
                resume()
            }
        @unknown default:
            break
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
        switch reason {
        case .oldDeviceUnavailable:
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
            guard AudioRoutePolicy.shouldResumeAfterRouteTransfer(
                pendingResume: pendingResume,
                playbackIntended: playbackIntended,
                hasCurrentTrack: currentTrack != nil,
                isPlaying: isPlaying,
                resumeBluetoothEnabled: resumeOnBluetoothConnection,
                currentOutputPortTypes: currentOutputs
            ) else {
                return
            }
            routeDisconnectPending = false
            resume()
        default:
            break
        }
    }

    private func handleMediaServicesReset() {
        let position = elapsedTime
        playbackIntended = false
        wasPlayingBeforeInterruption = false
        resumeAfterRouteTransfer = false
        isPlaying = false
        isBuffering = false
        publishPlaybackState(force: true)

        cancelContinuation()
        cancelStreamRefresh()
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
        loadCurrent(autoplay: false, startAt: position)
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

    private func handleOutputVolume(_ volume: Float) {
        let outputPortTypes = AVAudioSession.sharedInstance()
            .currentRoute.outputs.map(\.portType)
        guard AudioRoutePolicy.shouldPause(
            volume: volume,
            enabled: pauseAtMinimumVolume,
            isPlaying: isPlaying,
            outputPortTypes: outputPortTypes
        ) else {
            return
        }
        pause()
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
        if !didAttemptStreamRefresh, streamRefreshProvider != nil {
            refreshCurrentStream(autoplay: true)
            return
        }
        if advancePastFailedTrackIfPossible() {
            return
        }
        let urlError = error as? URLError
        errorMessage = L10n.text(
            urlError?.code == .cancelled
                ? "Аудиопоток был прерван. Повторите воспроизведение."
                : "Не удалось воспроизвести этот трек. "
                    + "Проверьте подключение и попробуйте ещё раз."
        )
        Haptics.error()
    }

    @discardableResult
    private func advancePastFailedTrackIfPossible() -> Bool {
        guard advanceOnPlaybackError,
              let currentIndex,
              !queue.isEmpty else {
            return false
        }

        if currentIndex + 1 < queue.count {
            cancelContinuation()
            cancelStreamRefresh()
            requiresStreamRefresh = false
            didAttemptStreamRefresh = false
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
        requiresStreamRefresh = false
        didAttemptStreamRefresh = false
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
                self.isBuffering = false
                self.isPlaying = false
                if !self.advancePastFailedTrackIfPossible() {
                    self.errorMessage = L10n.text(
                        "Не удалось обновить ссылку на аудиопоток. "
                            + "Проверьте подключение и повторите попытку."
                    )
                    self.publishPlaybackState(force: true)
                }
            }
        }
    }

    private func cancelContinuation() {
        continuationGeneration += 1
        continuationTask?.cancel()
        continuationTask = nil
    }

    private func cancelStreamRefresh() {
        streamRefreshGeneration += 1
        streamRefreshTask?.cancel()
        streamRefreshTask = nil
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

    private func persistPlayback() {
        guard !queue.isEmpty, let currentIndex else { return }
        let snapshot = PlaybackSnapshot(
            queue: queue,
            currentIndex: currentIndex,
            elapsedTime: elapsedTime
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: PlaybackSnapshot.key)
    }

    private func resetProgressForTrackTransition() {
        loadedTrackID = nil
        loadedOfflineTrackID = nil
        elapsedTime = 0
        duration = currentTrack?.duration ?? 0
        lastPersistedSecond = -1
        lastNowPlayingSecond = -1
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
        let restoredPosition = max(snapshot.elapsedTime, 0)
        elapsedTime = duration > 0
            ? min(restoredPosition, duration)
            : restoredPosition
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

    let queue: [Track]
    let currentIndex: Int
    let elapsedTime: TimeInterval
}
