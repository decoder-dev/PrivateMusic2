import XCTest
@testable import PrivateMusic

final class PlayerActionSheetTests: XCTestCase {
    func testActionSheetFitsSmallSupportedPhoneHeight() {
        XCTAssertGreaterThan(
            PlayerActionSheetMetrics.preferredHeight,
            400
        )
        XCTAssertLessThanOrEqual(
            PlayerActionSheetMetrics.preferredHeight,
            520
        )
    }

    func testActionSheetUsesAccessibleMinimumTapTargets() {
        XCTAssertGreaterThanOrEqual(
            PlayerActionSheetMetrics.minimumTapTarget,
            44
        )
    }

    func testAllSessionActionsAreEnabledWhenIdle() {
        let state = PlayerActionAvailability(
            hasSession: true,
            isUpdatingLibrary: false
        )

        XCTAssertTrue(state.canModifyLibrary)
        XCTAssertTrue(state.canAddToPlaylist)
        XCTAssertTrue(state.canShare)
        XCTAssertFalse(state.showsLibraryProgress)
        XCTAssertEqual(
            state.showsOfflineControls,
            OfflineDownloadsFeature.showsControls
        )
    }

    func testLibraryMutationDisablesOnlyLibraryAction() {
        let state = PlayerActionAvailability(
            hasSession: true,
            isUpdatingLibrary: true
        )

        XCTAssertFalse(state.canModifyLibrary)
        XCTAssertTrue(state.canAddToPlaylist)
        XCTAssertTrue(state.canShare)
        XCTAssertTrue(state.showsLibraryProgress)
        XCTAssertEqual(
            state.showsOfflineControls,
            OfflineDownloadsFeature.showsControls
        )
    }

    func testMetadataShareRemainsAvailableWithoutCredentials() {
        let state = PlayerActionAvailability(
            hasSession: false,
            isUpdatingLibrary: false
        )

        XCTAssertFalse(state.canModifyLibrary)
        XCTAssertFalse(state.canAddToPlaylist)
        XCTAssertTrue(state.canShare)
        XCTAssertFalse(state.showsLibraryProgress)
        XCTAssertEqual(
            state.showsOfflineControls,
            OfflineDownloadsFeature.showsControls
        )
    }

    func testShareSessionHidesOfflineControls() {
        let state = PlayerActionAvailability(
            hasSession: true,
            isUpdatingLibrary: false,
            showsOfflineControls: false
        )

        XCTAssertTrue(state.canShare)
        XCTAssertFalse(state.showsOfflineControls)
    }

    func testVacationBuildKeepsShareAndHidesDownloads() {
        XCTAssertFalse(
            OfflineDownloadsFeature.isEnabled,
            "Offline downloads stay off for the stable vacation build"
        )
        XCTAssertTrue(
            PlayerActionAvailability(
                hasSession: true,
                isUpdatingLibrary: false
            ).canShare
        )
    }
}

final class PlayerDismissGestureTests: XCTestCase {
    func testFastDownwardSwipeDismissesFromPlayerSurface() {
        XCTAssertTrue(
            PlayerDismissGesturePolicy.shouldDismiss(
                translation: CGSize(width: 12, height: 92),
                predictedEndTranslation: CGSize(width: 16, height: 180)
            )
        )
    }

    func testLongDownwardDragDismissesWithoutVelocity() {
        XCTAssertTrue(
            PlayerDismissGesturePolicy.shouldDismiss(
                translation: CGSize(width: 20, height: 150),
                predictedEndTranslation: CGSize(width: 20, height: 150)
            )
        )
    }

    func testHorizontalArtworkSwipeDoesNotDismissPlayer() {
        XCTAssertFalse(
            PlayerDismissGesturePolicy.shouldDismiss(
                translation: CGSize(width: 150, height: 90),
                predictedEndTranslation: CGSize(width: 210, height: 120)
            )
        )
    }

    func testUpwardAndShortDragsDoNotDismissPlayer() {
        XCTAssertFalse(
            PlayerDismissGesturePolicy.shouldDismiss(
                translation: CGSize(width: 0, height: -120),
                predictedEndTranslation: CGSize(width: 0, height: -180)
            )
        )
        XCTAssertFalse(
            PlayerDismissGesturePolicy.shouldDismiss(
                translation: CGSize(width: 0, height: 42),
                predictedEndTranslation: CGSize(width: 0, height: 78)
            )
        )
    }
}

final class PlayerArtworkCarouselPolicyTests: XCTestCase {
    func testMiddleTrackShowsPreviousAndNextArtwork() {
        let neighbors = PlayerArtworkCarouselPolicy.neighborIndices(
            queueCount: 3,
            currentIndex: 1,
            repeatMode: .off
        )

        XCTAssertEqual(neighbors.previous, 0)
        XCTAssertEqual(neighbors.next, 2)
    }

    func testQueueEdgesDoNotWrapWhenRepeatIsOff() {
        XCTAssertNil(
            PlayerArtworkCarouselPolicy.neighborIndices(
                queueCount: 3,
                currentIndex: 0,
                repeatMode: .off
            ).previous
        )
        XCTAssertNil(
            PlayerArtworkCarouselPolicy.neighborIndices(
                queueCount: 3,
                currentIndex: 2,
                repeatMode: .off
            ).next
        )
    }

    func testRepeatAllWrapsAdjacentArtworkAtQueueEdges() {
        let first = PlayerArtworkCarouselPolicy.neighborIndices(
            queueCount: 3,
            currentIndex: 0,
            repeatMode: .all
        )
        let last = PlayerArtworkCarouselPolicy.neighborIndices(
            queueCount: 3,
            currentIndex: 2,
            repeatMode: .all
        )

        XCTAssertEqual(first.previous, 2)
        XCTAssertEqual(last.next, 0)
    }

    func testCarouselKeepsMainArtworkDominantAndVisible() {
        let layout = PlayerArtworkCarouselPolicy.layout(for: 320)

        XCTAssertEqual(layout.centerSize, 268.8, accuracy: 0.001)
        XCTAssertLessThan(layout.neighborSize, layout.centerSize)
        XCTAssertGreaterThan(layout.neighborOffset, layout.centerSize / 2)
        XCTAssertLessThan(layout.neighborOffset, 320)
    }
}

@MainActor
final class PlayerSleepTimerTests: XCTestCase {
    func testSleepTimerCanBeScheduledAndCancelledFromPlayer() throws {
        let suite = "PlayerSleepTimerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let history = ListeningHistoryStore(defaults: defaults)
        let player = AudioPlayer(
            settings: settings,
            historyStore: history,
            defaults: defaults
        )
        let startedAt = Date()

        player.scheduleSleepTimer(minutes: 15)

        let endDate = try XCTUnwrap(player.sleepTimerEndDate)
        XCTAssertEqual(
            endDate.timeIntervalSince(startedAt),
            15 * 60,
            accuracy: 2
        )

        player.cancelSleepTimer()
        XCTAssertNil(player.sleepTimerEndDate)
    }
}

final class PlayerContentLayoutTests: XCTestCase {
    func testCompactPhoneReservesBottomDockWithoutOverflow() {
        let metrics = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 375, height: 667),
            hasAlbum: true
        )

        XCTAssertEqual(metrics.mode, .compact)
        XCTAssertLessThanOrEqual(metrics.minimumContentHeight, 667)
        XCTAssertGreaterThan(metrics.artworkSize, 0)
        XCTAssertLessThanOrEqual(
            metrics.artworkSize,
            metrics.contentWidth
        )
        XCTAssertEqual(
            metrics.quickActionsBottomY(containerHeight: 667),
            657
        )
        XCTAssertEqual(metrics.quickActionsHeight, 64)
    }

    func testStandardPhonePinsDockAboveHomeIndicator() {
        let metrics = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 390, height: 844),
            safeBottom: 34,
            hasAlbum: true
        )

        XCTAssertEqual(metrics.mode, .standard)
        XCTAssertEqual(metrics.bottomPadding, 34)
        XCTAssertEqual(
            metrics.quickActionsBottomY(containerHeight: 844),
            810
        )
        XCTAssertLessThanOrEqual(metrics.minimumContentHeight, 844)
    }

    func testTallPhoneUsesAvailableArtworkSpace() {
        let metrics = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 430, height: 932),
            safeBottom: 34,
            hasAlbum: true
        )

        XCTAssertEqual(metrics.mode, .tall)
        XCTAssertGreaterThan(metrics.artworkSize, 300)
        XCTAssertLessThanOrEqual(
            metrics.artworkSize,
            metrics.contentWidth
        )
        XCTAssertLessThanOrEqual(metrics.minimumContentHeight, 932)
    }

    func testLandscapeUsesTwoColumnsAndNotchInsets() {
        let metrics = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 844, height: 390),
            safeBottom: 21,
            safeLeading: 47,
            safeTrailing: 47,
            hasAlbum: true
        )

        XCTAssertEqual(metrics.mode, .landscape)
        XCTAssertGreaterThanOrEqual(metrics.leadingPadding, 55)
        XCTAssertGreaterThanOrEqual(metrics.trailingPadding, 55)
        XCTAssertGreaterThan(metrics.landscapeColumnSpacing, 0)
        XCTAssertLessThanOrEqual(metrics.minimumContentHeight, 390)
        XCTAssertEqual(
            metrics.quickActionsBottomY(containerHeight: 390),
            369
        )
    }

    func testLongerMetadataReducesArtworkInsteadOfDockSpace() {
        let withAlbum = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 375, height: 667),
            hasAlbum: true
        )
        let withoutAlbum = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 375, height: 667),
            hasAlbum: false
        )

        XCTAssertLessThanOrEqual(
            withAlbum.artworkSize,
            withoutAlbum.artworkSize
        )
        XCTAssertEqual(
            withAlbum.quickActionsHeight,
            withoutAlbum.quickActionsHeight
        )
        XCTAssertEqual(
            withAlbum.bottomPadding,
            withoutAlbum.bottomPadding
        )
    }

    func testAccessibilityTextStillFitsCompactPhone() {
        let normal = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 375, height: 667),
            hasAlbum: true
        )
        let accessible = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 375, height: 667),
            usesAccessibilityText: true,
            hasAlbum: true
        )

        XCTAssertTrue(accessible.usesAccessibilityText)
        XCTAssertEqual(accessible.quickActionsHeight, 72)
        XCTAssertGreaterThanOrEqual(accessible.artworkSize, 0)
        XCTAssertLessThanOrEqual(
            accessible.quickActionsBottomY(containerHeight: 667),
            667
        )
        XCTAssertLessThanOrEqual(normal.quickActionsHeight, 64)
        XCTAssertEqual(
            accessible.quickActionsBottomY(containerHeight: 667),
            normal.quickActionsBottomY(containerHeight: 667)
        )
    }

    func testPortraitMetricsRemainContinuousAcrossModeThresholds() {
        let compactEdge = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 390, height: 719)
        )
        let standardEdge = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 390, height: 720)
        )
        let standardTallEdge = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 390, height: 859)
        )
        let tallEdge = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 390, height: 860)
        )

        XCTAssertEqual(compactEdge.mode, .compact)
        XCTAssertEqual(standardEdge.mode, .standard)
        XCTAssertEqual(standardTallEdge.mode, .standard)
        XCTAssertEqual(tallEdge.mode, .tall)
        XCTAssertLessThan(
            abs(compactEdge.artworkSize - standardEdge.artworkSize),
            3
        )
        XCTAssertLessThan(
            abs(
                standardTallEdge.artworkSize
                    - tallEdge.artworkSize
            ),
            3
        )
        XCTAssertLessThan(
            abs(
                compactEdge.artworkTopSpacing
                    - standardEdge.artworkTopSpacing
            ),
            1
        )
        XCTAssertLessThan(
            abs(
                standardTallEdge.artworkTopSpacing
                    - tallEdge.artworkTopSpacing
            ),
            1
        )
    }
}
