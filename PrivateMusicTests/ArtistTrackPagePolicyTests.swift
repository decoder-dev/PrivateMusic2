import XCTest
@testable import PrivateMusic

final class ArtistTrackPagePolicyTests: XCTestCase {
    /// The next page is asked for before the listener reaches the bottom, so
    /// the rows are already there when they arrive.
    func testAskingStartsBeforeTheLastRow() {
        let loaded = 50
        let trigger = loaded - ArtistTrackPagePolicy.prefetchDistance

        XCTAssertTrue(
            ArtistTrackPagePolicy.shouldLoadMore(
                visibleIndex: trigger,
                loadedCount: loaded,
                hasMore: true,
                isLoading: false
            )
        )
        XCTAssertFalse(
            ArtistTrackPagePolicy.shouldLoadMore(
                visibleIndex: trigger - 1,
                loadedCount: loaded,
                hasMore: true,
                isLoading: false
            )
        )
    }

    /// VK saying "no continuation" ends the list — the artist page must not
    /// keep asking for a page that is not there.
    func testNoContinuationStopsAsking() {
        XCTAssertFalse(
            ArtistTrackPagePolicy.shouldLoadMore(
                visibleIndex: 49,
                loadedCount: 50,
                hasMore: false,
                isLoading: false
            )
        )
    }

    /// Rows appear in bursts as the list scrolls, and every one of them runs
    /// this check. Without the in-flight guard a single flick would fire the
    /// same page request several times over.
    func testAPageInFlightSuppressesFurtherRequests() {
        XCTAssertFalse(
            ArtistTrackPagePolicy.shouldLoadMore(
                visibleIndex: 49,
                loadedCount: 50,
                hasMore: true,
                isLoading: true
            )
        )
    }

    func testAnEmptyListNeverAsks() {
        XCTAssertFalse(
            ArtistTrackPagePolicy.shouldLoadMore(
                visibleIndex: 0,
                loadedCount: 0,
                hasMore: true,
                isLoading: false
            )
        )
    }

    /// A first page shorter than the prefetch distance still has to be able
    /// to pull the next one, or a small first answer would strand the list.
    func testAShortFirstPageStillAsks() {
        XCTAssertTrue(
            ArtistTrackPagePolicy.shouldLoadMore(
                visibleIndex: 0,
                loadedCount: 3,
                hasMore: true,
                isLoading: false
            )
        )
    }

    func testPageSizeMatchesTheFirstLoad() {
        XCTAssertEqual(ArtistTrackPagePolicy.pageSize, 50)
    }
}
