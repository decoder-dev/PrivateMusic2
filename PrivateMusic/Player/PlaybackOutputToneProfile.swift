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

    /// Same decision with the device names in hand. Bluetooth earbuds and
    /// Bluetooth speakers arrive as the very same port type, so the name is
    /// the only thing that tells a pair of AirPods (worn on the head: full
    /// spatial width, no boom cut) from a party speaker (room profile).
    /// Anything the name does not give away keeps the milder room profile.
    static func resolve(
        outputs: [(port: AVAudioSession.Port, name: String)]
    ) -> PlaybackOutputToneProfile {
        let ports = outputs.map(\.port)
        if !ports.contains(where: isCabinPort),
           outputs.contains(where: {
               ($0.port == .bluetoothA2DP || $0.port == .bluetoothLE)
                   && looksLikeHeadphones($0.name)
           }) {
            return .intimate
        }
        return resolve(outputPortTypes: ports)
    }

    static func looksLikeHeadphones(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return headphoneNameMarkers.contains { lowered.contains($0) }
    }

    private static let headphoneNameMarkers = [
        "airpods", "buds", "earbuds", "earphone", "headphone", "headset",
        "beats", "powerbeats", "wh-1000", "wf-1000", "наушник"
    ]

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
