import AVFoundation
import Foundation

/// Route-aware tone shaping so spatial / EQ does not turn car cabins,
/// phone speakers, and Bluetooth boxes into a hollow "barrel".
enum PlaybackOutputToneProfile: Equatable {
    /// Headphones / wired listening — keep full spatial width.
    case intimate
    /// Built-in speaker — phone body already booms the low mids.
    case room
    /// Car, Bluetooth speakers, AirPlay, line-out — cabin/box resonance.
    case cabin

    static func resolve(
        outputPortTypes: [AVAudioSession.Port]
    ) -> PlaybackOutputToneProfile {
        if outputPortTypes.contains(where: isCabinPort) {
            return .cabin
        }
        if outputPortTypes.contains(where: isRoomPort) {
            return .room
        }
        if outputPortTypes.contains(where: isIntimatePort) {
            return .intimate
        }
        return outputPortTypes.isEmpty ? .intimate : .cabin
    }

    /// Scale user spatial intensity so cabin mono-downmix stays tight.
    var spatialIntensityScale: Double {
        switch self {
        case .intimate: return 1
        case .room: return 0.72
        case .cabin: return 0.52
        }
    }

    /// Mild low-shelf cut around the muddy "barrel" band (~140 Hz).
    var boomCutDB: Double {
        switch self {
        case .intimate: return 0
        case .room: return -1.0
        case .cabin: return -2.0
        }
    }

    var needsClarityProcessing: Bool {
        boomCutDB < -0.05
    }

    private static func isCabinPort(_ port: AVAudioSession.Port) -> Bool {
        // Keep Bluetooth A2DP out of cabin: AirPods share that port type with
        // BT speakers, so they get the milder `.room` profile instead.
        port == .carAudio
            || port == .airPlay
            || port == .lineOut
            || port == .HDMI
            || port == .usbAudio
    }

    private static func isIntimatePort(_ port: AVAudioSession.Port) -> Bool {
        port == .headphones
            || port == .bluetoothHFP
    }

    private static func isRoomPort(_ port: AVAudioSession.Port) -> Bool {
        port == .builtInSpeaker
            || port == .bluetoothA2DP
            || port == .bluetoothLE
    }
}
