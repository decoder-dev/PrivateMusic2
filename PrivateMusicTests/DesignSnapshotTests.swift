import SwiftUI
import UIKit
import XCTest
@testable import PrivateMusic

/// Render the real SwiftUI components on the CI simulator. Attachments are
/// review evidence, not an assertion that visual quality can be automated.
@MainActor
final class DesignSnapshotTests: XCTestCase {
    func testCaptureAppearanceAndCoreComposition() throws {
        let suite = "DesignSnapshotTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let environment = AppEnvironment(keychain: KeychainStore(service: suite))
        for theme in AppTheme.allCases {
            settings.theme = theme
            settings.appearance = theme == .dark ? .dark : .light
            capture(ConnectView(), name: "connect-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { AppearanceSettingsView() },
                    name: "appearance-\(theme.rawValue)", environment: environment, settings: settings)
            capture(homeComposition(width: 390), name: "home-\(theme.rawValue)",
                    environment: environment, settings: settings)
        }
        settings.theme = .light
        settings.palette = .banana
        settings.accentChoice = .banana
        capture(homeComposition(width: 320), name: "home-compact-cream",
                width: 320, height: 700, environment: environment, settings: settings)
        capture(NavigationStack { AppearanceSettingsView() }.dynamicTypeSize(.accessibility3),
                name: "appearance-accessibility", environment: environment, settings: settings)
    }

    private func homeComposition(width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BubbleSpacing.section) {
                HomeStageView(width: width, horizontalPadding: 16, foregroundTopOrigin: 16)
                PremiumSectionHeader("recently_played")
                AppGroupedSurface {
                    TrackRowContent(artworkURL: nil, title: "Тихий вечер", artist: "Private Music",
                                    showsLikedBadge: false, durationText: "3:42")
                    TrackRowContent(artworkURL: nil, title: "Навстречу солнцу", artist: "Private Music",
                                    showsLikedBadge: false, durationText: "4:16")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(ThemeBackground())
    }

    private func capture<V: View>(
        _ view: V, name: String, width: CGFloat = 390, height: CGFloat = 844,
        environment: AppEnvironment, settings: AppSettings
    ) {
        let content = view
            .environment(environment)
            .environment(settings)
            .environment(environment.sessionStore)
            .environment(environment.player)
            .environment(environment.player.highlight)
            .environment(environment.player.progress)
            .environment(environment.libraryStore)
            .environment(environment.offlineStore)
            .environment(environment.historyStore)
            .environment(environment.homeCatalogStore)
            .environment(\.colorScheme, settings.theme.colorScheme)
            .tint(settings.accent)
        let controller = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.overrideUserInterfaceStyle = settings.theme == .dark ? .dark : .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
    }
}
