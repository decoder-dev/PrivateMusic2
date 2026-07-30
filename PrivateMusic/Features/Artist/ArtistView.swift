import SwiftUI

struct ArtistView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let artist: String
    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            Group {
                if isLoading && tracks.isEmpty {
                    ArtistLoadingView(artist: artist)
                } else if tracks.isEmpty {
                    emptyContent
                } else {
                    trackContent
                }
            }
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeBackground())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: isLoading
        )
        .task(id: artist) {
            await load(resetContent: true)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("Исполнитель"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(artist)
                    .font(.headline)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(
                        Color(uiColor: .tertiarySystemFill),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Закрыть"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(minHeight: 58)
    }

    private var trackContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                artistHeader

                if let errorMessage {
                    ArtistInlineError(
                        message: errorMessage,
                        retry: { Task { await load(resetContent: false) } }
                    )
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                }

                HStack {
                    Text(L10n.text("Треки исполнителя"))
                        .font(.headline)
                    Spacer()
                    Text(L10n.trackCount(tracks.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)

                ForEach(
                    Array(tracks.enumerated()),
                    id: \.element.id
                ) { index, track in
                    TrackRow(track: track, queue: tracks)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 5)

                    if index < tracks.count - 1 {
                        Divider()
                            .padding(.leading, 82)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await load(resetContent: false)
        }
    }

    private var artistHeader: some View {
        HStack(spacing: 16) {
            AsyncArtwork(
                url: tracks.first?.artworkURL,
                size: 88
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(artist)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                Text(L10n.text("Музыка"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var emptyContent: some View {
        ArtistMessageView(
            title: L10n.text("Исполнитель недоступен"),
            description: errorMessage
                ?? L10n.text(
                    "Для этого исполнителя VK не вернул доступных треков."
                ),
            systemImage: errorMessage == nil
                ? "music.note.list"
                : "exclamationmark.circle",
            retry: sessionStore.accessToken == nil
                ? nil
                : { Task { await load(resetContent: true) } }
        )
    }

    @MainActor
    private func load(resetContent: Bool) async {
        let requestedArtist = artist
        if resetContent {
            tracks = []
        }
        errorMessage = nil

        guard sessionStore.accessToken != nil else {
            isLoading = false
            errorMessage = L10n.text(
                "Подключите VK, чтобы открыть страницу исполнителя."
            )
            return
        }

        isLoading = tracks.isEmpty
        defer {
            if artist == requestedArtist {
                isLoading = false
            }
        }

        do {
            let page = try await fetchPage(for: requestedArtist)
            try Task.checkCancellation()
            guard artist == requestedArtist else { return }

            tracks = ArtistTrackFilter.filtered(
                page.items,
                artist: requestedArtist
            )
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard artist == requestedArtist else { return }
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func fetchPage(
        for requestedArtist: String
    ) async throws -> MusicPage<Track> {
        let appEnvironment = environment
        return try await withThrowingTaskGroup(
            of: MusicPage<Track>.self
        ) { group in
            group.addTask { @MainActor in
                try await appEnvironment.withAuthorizedToken { token in
                    try await appEnvironment.musicService.search(
                        query: requestedArtist,
                        accessToken: token,
                        offset: 0,
                        count: 50
                    )
                }
            }
            group.addTask {
                try await Task.sleep(
                    for: .seconds(ArtistLoadPolicy.timeout)
                )
                throw APIError.timedOut
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }
}

enum ArtistLoadPolicy {
    static let timeout: TimeInterval = 25
}

enum ArtistTrackFilter {
    static func filtered(_ tracks: [Track], artist: String) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { track in
            matches(track.artist, artist: artist)
                && seen.insert(track.id).inserted
        }
    }

    static func matches(_ candidate: String, artist: String) -> Bool {
        let target = normalized(artist)
        guard !target.isEmpty else { return false }
        let value = normalized(candidate)
        if value == target {
            return true
        }

        return collaborationParts(in: value).contains(target)
    }

    private static func collaborationParts(in value: String) -> [String] {
        let separators = [
            ",",
            ";",
            " feat. ",
            " feat ",
            " featuring ",
            " ft. ",
            " ft "
        ]
        return separators.reduce([value]) { parts, separator in
            parts.flatMap {
                $0.components(separatedBy: separator)
            }
        }
        .map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ArtistLoadingView: View {
    let artist: String

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .frame(width: 88, height: 88)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(artist)
                            .font(.title3.weight(.bold))
                            .lineLimit(2)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(uiColor: .tertiarySystemFill))
                            .frame(width: 104, height: 12)
                    }

                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)

                HStack {
                    Text(L10n.text("Загружаем исполнителя…"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 10)

                ForEach(0..<4, id: \.self) { _ in
                    ArtistLoadingRow()
                        .padding(.horizontal, 18)
                        .padding(.vertical, 5)
                }
            }
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("Загружаем исполнителя…"))
    }
}

private struct ArtistLoadingRow: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(uiColor: .tertiarySystemFill))
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(maxWidth: 190)
                    .frame(height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(maxWidth: 120)
                    .frame(height: 10)
            }

            Spacer()
        }
        .frame(minHeight: 56)
    }
}

private struct ArtistMessageView: View {
    let title: String
    let description: String
    let systemImage: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let retry {
                Button(L10n.text("Повторить"), action: retry)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ArtistInlineError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(L10n.text("Повторить"), action: retry)
                .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }
}
