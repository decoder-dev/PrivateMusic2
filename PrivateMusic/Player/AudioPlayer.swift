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

    private let player = AVPlayer()
    private let nowPlaying = NowPlayingController()
    private let equalizer = EqualizerDSP()
    private var timeObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var remoteCommandTokens: [Any] = []
    private var sleepTask: Task<Void, Never>?
    private var streamUserAgent: String?
    private var itemStatusObservation: NSKeyValueObservation?

    var currentTrack: Track? {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            return nil
        }
        return queue[currentIndex]
    }

    init(
        settings: AppSettings,
        userAgent: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.streamUserAgent = userAgent
        shuffleEnabled = defaults.bool(forKey: "player.shuffle")
        repeatMode = RepeatMode(
            rawValue: defaults.string(forKey: "player.repeat") ?? ""
        ) ?? .off
        player.automaticallyWaitsToMinimizeStalling = true
        configureAudioSession()
        configureRemoteCommands()
        observePlayer()
        settings.$equalizerEnabled
            .combineLatest(settings.$equalizerGains)
            .sink { [weak self] enabled, gains in
                self?.equalizer.update(enabled: enabled, gains: gains)
            }
            .store(in: &cancellables)
    }

    func configureNetwork(userAgent: String?) {
        let cleaned = userAgent?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        streamUserAgent = cleaned?.isEmpty == false ? cleaned : nil
    }

    func play(_ track: Track, in tracks: [Track]) {
        if shuffleEnabled {
            queue = [track] + tracks.filter { $0 != track }.shuffled()
            currentIndex = 0
        } else {
            queue = tracks
            currentIndex = tracks.firstIndex(of: track) ?? 0
        }
        loadCurrentAndPlay()
    }

    func playNext(_ track: Track) {
        guard let currentIndex else {
            play(track, in: [track])
            return
        }
        queue.removeAll { $0.id == track.id }
        queue.insert(track, at: min(currentIndex + 1, queue.count))
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        defaults.set(shuffleEnabled, forKey: "player.shuffle")
        guard let currentTrack else { return }
        let remaining = queue.filter { $0.id != currentTrack.id }
        queue = [currentTrack]
            + (shuffleEnabled ? remaining.shuffled() : remaining)
        currentIndex = 0
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
        guard player.currentItem != nil else {
            loadCurrentAndPlay()
            return
        }
        activateAudioSession()
        player.play()
        isPlaying = true
        publishPlaybackState()
    }

    func pause() {
        player.pause()
        isPlaying = false
        publishPlaybackState()
    }

    func next() {
        guard let currentIndex, !queue.isEmpty else { return }
        let nextIndex = queue.index(after: currentIndex)
        if nextIndex >= queue.endIndex, repeatMode == .off {
            pause()
            seek(to: 0)
            return
        }
        self.currentIndex = nextIndex < queue.endIndex ? nextIndex : 0
        loadCurrentAndPlay()
    }

    func previous() {
        if elapsedTime > 4 {
            seek(to: 0)
            return
        }
        guard let currentIndex, !queue.isEmpty else { return }
        self.currentIndex = currentIndex > 0 ? currentIndex - 1 : queue.count - 1
        loadCurrentAndPlay()
    }

    func seek(to seconds: TimeInterval) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        elapsedTime = seconds
        publishPlaybackState()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        queue = []
        currentIndex = nil
        elapsedTime = 0
        duration = 0
        isPlaying = false
        isBuffering = false
        nowPlaying.clear()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func loadCurrentAndPlay() {
        guard let track = currentTrack else { return }
        guard let url = track.streamURL else {
            errorMessage = "Для этого трека отсутствует доступный аудиопоток."
            isPlaying = false
            nowPlaying.update(track: track, elapsedTime: 0, rate: 0)
            return
        }

        var headers = [
            "Referer": "https://vk.com/",
            "Origin": "https://vk.com"
        ]
        if let streamUserAgent {
            headers["User-Agent"] = streamUserAgent
        }
        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
        )
        let item = AVPlayerItem(asset: asset)
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isBuffering = false
                case .failed:
                    self.isPlaying = false
                    self.isBuffering = false
                    self.errorMessage = item.error?.localizedDescription
                        ?? "VK не вернул рабочий аудиопоток."
                    self.publishPlaybackState()
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
        elapsedTime = 0
        duration = track.duration
        activateAudioSession()
        player.play()
        isPlaying = true
        isBuffering = true
        nowPlaying.update(track: track, elapsedTime: 0, rate: 1)
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                options: []
            )
        } catch {
            errorMessage = "Не удалось настроить фоновое аудио: \(error.localizedDescription)"
        }
    }

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            errorMessage = "Не удалось включить звук: \(error.localizedDescription)"
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

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
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
            }
        }

        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.advanceAfterCompletion() }
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
                self?.isPlaying = false
                self?.errorMessage = error?.localizedDescription
                    ?? "Не удалось воспроизвести аудиопоток."
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
            isPlaying = false
            publishPlaybackState()
        case .ended:
            let rawOptions = notification.userInfo?[
                AVAudioSessionInterruptionOptionKey
            ] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(
                rawValue: rawOptions
            ).contains(.shouldResume) {
                resume()
            }
        @unknown default:
            break
        }
    }

    private func advanceAfterCompletion() {
        if repeatMode == .one {
            seek(to: 0)
            resume()
        } else {
            next()
        }
    }

    private func publishPlaybackState() {
        nowPlaying.updatePlayback(
            elapsedTime: elapsedTime,
            rate: isPlaying ? 1 : 0
        )
    }
}
