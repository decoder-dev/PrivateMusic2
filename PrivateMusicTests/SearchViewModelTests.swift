import XCTest
@testable import PrivateMusic

@MainActor
final class SearchViewModelTests: XCTestCase {
    func testShortQueryStaysInHintStateWithoutCallingService() async {
        let context = makeModel()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        var requestCount = 0
        context.model.query = "a"

        context.model.schedule { _, _, _ in
            requestCount += 1
            return Self.page(items: [])
        }
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(context.model.state, .needsMoreCharacters)
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(context.model.errorMessage)
    }

    func testNewQueryCancelsInFlightSearchAndKeepsLatestResults() async {
        let context = makeModel(debounce: .zero)
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        var requestedQueries: [String] = []
        let operation: SearchViewModel.SearchOperation = { query, _, _ in
            requestedQueries.append(query)
            if query == "first" {
                try await Task.sleep(for: .milliseconds(250))
                return Self.page(items: [Self.track(id: 1)])
            }
            return Self.page(items: [Self.track(id: 2)])
        }

        context.model.query = "first"
        context.model.submit(operation: operation)
        await waitUntil { requestedQueries.contains("first") }

        context.model.query = "second"
        context.model.submit(operation: operation)
        await waitUntil {
            context.model.tracks.first?.id == Self.track(id: 2).id
        }

        XCTAssertEqual(context.model.tracks.map(\.id), ["10_2"])
        XCTAssertEqual(context.model.state, .results)
        XCTAssertNil(context.model.errorMessage)
    }

    func testCancelledTransportDoesNotBecomeVisibleError() async {
        let context = makeModel(debounce: .zero)
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        context.model.query = "query"

        context.model.submit { _, _, _ in
            throw URLError(.cancelled)
        }
        await waitUntil { !context.model.isLoading }

        XCTAssertNil(context.model.errorMessage)
        XCTAssertNotEqual(
            context.model.state,
            .failure(URLError(.cancelled).localizedDescription)
        )
    }

    func testEmptyResponseProducesEmptyStateForCompletedQuery() async {
        let context = makeModel(debounce: .zero)
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        context.model.query = "missing"

        context.model.submit { _, _, _ in
            Self.page(items: [])
        }
        await waitUntil { !context.model.isLoading }

        XCTAssertEqual(context.model.state, .empty)
        XCTAssertTrue(context.model.tracks.isEmpty)
    }

    func testPlaylistResultsProduceResultsStateAndRecentQuery() async {
        let context = makeModel(debounce: .zero)
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        context.model.query = "road"

        context.model.submitPlaylists { query, _, _ in
            Self.playlistPage(items: [
                Self.playlist(id: 1, title: "Road Mix"),
                Self.playlist(id: 2, title: "Evening")
            ].filter {
                $0.title.localizedCaseInsensitiveContains(query)
            })
        }
        await waitUntil { !context.model.isLoadingPlaylists }

        XCTAssertEqual(context.model.playlists.map(\.title), ["Road Mix"])
        XCTAssertEqual(context.model.state, .results)
        XCTAssertEqual(context.model.recentQueries.first, "road")
    }

    func testChangingQueryResetsPaginationLoadingState() async {
        let context = makeModel(debounce: .seconds(1))
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        context.model.query = "initial"
        context.model.submit { _, _, _ in
            Self.page(
                items: [Self.track(id: 1)],
                nextOffset: 100
            )
        }
        await waitUntil { context.model.state == .results }

        let pagination = Task { @MainActor in
            await context.model.loadMore { _, _, _ in
                try await Task.sleep(for: .milliseconds(250))
                return Self.page(items: [Self.track(id: 2)])
            }
        }
        await waitUntil { context.model.isLoadingMore }

        context.model.query = "replacement"
        context.model.schedule { _, _, _ in
            Self.page(items: [])
        }

        XCTAssertFalse(context.model.isLoadingMore)
        pagination.cancel()
    }

    func testHistoryIsTrimmedDeduplicatedAndLimited() {
        let values = [
            " Song ",
            "song",
            "",
            "a",
            "Two",
            "Three",
            "Four",
            "Five",
            "Six",
            "Seven",
            "Eight",
            "Nine",
            "Ten",
            "Eleven"
        ]

        let normalized = SearchViewModel.normalizedHistory(values)

        XCTAssertEqual(normalized.first, "Song")
        XCTAssertEqual(normalized.count, 10)
        XCTAssertEqual(
            normalized.filter {
                $0.localizedCaseInsensitiveCompare("song") == .orderedSame
            }.count,
            1
        )
    }

    private func makeModel(
        debounce: Duration = .milliseconds(10)
    ) -> (
        model: SearchViewModel,
        defaults: UserDefaults,
        suite: String
    ) {
        let suite = "SearchViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (
            SearchViewModel(
                defaults: defaults,
                debounceDuration: debounce
            ),
            defaults,
            suite
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private nonisolated static func page(
        items: [Track],
        nextOffset: Int? = nil
    ) -> MusicPage<Track> {
        MusicPage(
            items: items,
            totalCount: items.count,
            nextOffset: nextOffset
        )
    }

    private nonisolated static func playlistPage(
        items: [Playlist],
        nextOffset: Int? = nil
    ) -> MusicPage<Playlist> {
        MusicPage(
            items: items,
            totalCount: items.count,
            nextOffset: nextOffset
        )
    }

    private nonisolated static func track(id: Int) -> Track {
        Track(
            trackID: id,
            ownerID: 10,
            title: "Track \(id)",
            artist: "Artist",
            duration: 180,
            streamURL: nil,
            artworkURL: nil
        )
    }

    private nonisolated static func playlist(
        id: Int,
        title: String
    ) -> Playlist {
        Playlist(
            id: id,
            ownerID: 10,
            title: title,
            count: 12
        )
    }
}
