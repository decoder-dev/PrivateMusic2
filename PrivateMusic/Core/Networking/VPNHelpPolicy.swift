import Foundation

/// A troubleshooting suggestion, never a claim that a VPN was detected.
/// Authentication, content restrictions and offline mode need different help.
enum VPNHelpPolicy {
    static func shouldOfferHelp(for error: Error) -> Bool {
        shouldOfferHelp(for: error, remainingDepth: 3)
    }

    private static func shouldOfferHelp(for error: Error, remainingDepth: Int) -> Bool {
        guard !(error is CancellationError) else { return false }
        if let error = error as? APIError {
            switch error {
            case .timedOut, .transport:
                return true
            default:
                return false
            }
        }
        guard let error = error as? URLError else {
            guard remainingDepth > 0,
                  let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error else {
                return false
            }
            return shouldOfferHelp(for: underlying, remainingDepth: remainingDepth - 1)
        }
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .networkConnectionLost, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}
