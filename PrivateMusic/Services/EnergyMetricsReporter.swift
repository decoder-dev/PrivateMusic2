import Foundation
import MetricKit

/// Writes the system's daily energy and usage summary into the app log, so a
/// log export answers "where does the battery go" with numbers instead of
/// guesses: foreground / background / background-audio time, CPU, GPU, and
/// how much each radio moved. MetricKit delivers roughly once a day.
final class EnergyMetricsReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            AppLog.shared.info(.app, Self.summary(of: payload))
        }
    }

    static func summary(of payload: MXMetricPayload) -> String {
        func minutes(_ value: Measurement<UnitDuration>?) -> String {
            guard let value else { return "n/a" }
            return String(format: "%.1fmin", value.converted(to: .minutes).value)
        }
        func seconds(_ value: Measurement<UnitDuration>?) -> String {
            guard let value else { return "n/a" }
            return String(format: "%.0fs", value.converted(to: .seconds).value)
        }
        func megabytes(_ value: Measurement<UnitInformationStorage>?) -> String {
            guard let value else { return "n/a" }
            return String(format: "%.1fMB", value.converted(to: .megabytes).value)
        }
        let time = payload.applicationTimeMetrics
        let network = payload.networkTransferMetrics
        let fmt = ISO8601DateFormatter()
        return "Daily metrics \(fmt.string(from: payload.timeStampBegin))"
            + "..\(fmt.string(from: payload.timeStampEnd))"
            + " foreground=\(minutes(time?.cumulativeForegroundTime))"
            + " background=\(minutes(time?.cumulativeBackgroundTime))"
            + " backgroundAudio=\(minutes(time?.cumulativeBackgroundAudioTime))"
            + " cpu=\(seconds(payload.cpuMetrics?.cumulativeCPUTime))"
            + " gpu=\(seconds(payload.gpuMetrics?.cumulativeGPUTime))"
            + " cellularDown=\(megabytes(network?.cumulativeCellularDownload))"
            + " wifiDown=\(megabytes(network?.cumulativeWifiDownload))"
            + " diskWrites=\(megabytes(payload.diskIOMetrics?.cumulativeLogicalWrites))"
    }
}
