import SwiftUI
import Observation

@MainActor @Observable
final class FriendsMusicModel {
    private(set) var friends: [UserProfile] = []
    private(set) var tracks: [Track] = []
    private(set) var playlists: [Playlist] = []
    private(set) var error: String?
    private(set) var loading = false
    private(set) var nextOffset: Int? = 0
    private var generation = UUID()

    func reset() {
        generation = UUID()
        friends = []; tracks = []; playlists = []; error = nil
        loading = false; nextOffset = 0
    }

    func load(environment: AppEnvironment, ownerID: Int? = nil, playlistsOnly: Bool = false) async {
        guard !loading, let offset = nextOffset else { return }
        loading = true; error = nil
        let request = generation
        let account = environment.sessionStore.resolvedOfflineAccountID
        defer { if generation == request { loading = false } }
        do {
            if let ownerID {
                if playlistsOnly {
                    let page = try await environment.withAuthorizedToken { token in
                        try await environment.musicService.friendPlaylists(ownerID: ownerID,
                            accessToken: token, offset: offset, count: 100)
                    }
                    try Task.checkCancellation()
                    guard generation == request, account == environment.sessionStore.resolvedOfflineAccountID else { return }
                    var seen = Set(playlists.map(\.id))
                    playlists += page.items.filter { seen.insert($0.id).inserted }
                    nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
                } else {
                    let page = try await environment.withAuthorizedToken { token in
                        try await environment.musicService.friendTracks(ownerID: ownerID,
                            accessToken: token, offset: offset, count: 100)
                    }
                    try Task.checkCancellation()
                    guard generation == request, account == environment.sessionStore.resolvedOfflineAccountID else { return }
                    var seen = Set(tracks.map(\.id))
                    tracks += page.items.filter { seen.insert($0.id).inserted }
                    nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
                }
            } else {
                let page = try await environment.withAuthorizedToken { token in
                    try await environment.musicService.friends(accessToken: token, offset: offset, count: 100)
                }
                try Task.checkCancellation()
                guard generation == request, account == environment.sessionStore.resolvedOfflineAccountID else { return }
                var seen = Set(friends.map(\.id))
                friends += page.items.filter { seen.insert($0.id).inserted }
                nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
            }
        } catch is CancellationError {
        } catch {
            if generation == request { self.error = error.localizedDescription }
        }
    }
}

struct FriendsMusicView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @State private var model = FriendsMusicModel()

    var body: some View {
        List {
            ForEach(model.friends, id: \.id) { friend in
                NavigationLink {
                    FriendLibraryView(friend: friend)
                } label: {
                    HStack(spacing: 12) {
                        CachedRemoteImage(url: friend.photoURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                        }
                        .frame(width: 44, height: 44).clipShape(Circle()).accessibilityHidden(true)
                        Text(friend.displayName).font(.body)
                    }.padding(.vertical, 4)
                }
            }
            if let error = model.error {
                Text(error).foregroundStyle(.secondary)
            }
            if model.loading { ProgressView().frame(maxWidth: .infinity) }
            else if model.nextOffset != nil {
                Button(L10n.text(model.error == nil ? "features.load_more" : "action.retry")) {
                    Task { await model.load(environment: environment) }
                }
            }
            if !model.loading && model.error == nil && model.friends.isEmpty && model.nextOffset == nil {
                Text(L10n.text("features.friends.empty")).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.text("features.friends"))
        .clearsMiniPlayer()
        .task(id: sessionStore.accessToken) { model.reset(); await model.load(environment: environment) }
        .refreshable { model.reset(); await model.load(environment: environment) }
    }
}

private struct FriendLibraryView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    let friend: UserProfile
    @State private var showsPlaylists = false
    @State private var model = FriendsMusicModel()

    var body: some View {
        List {
            Picker(L10n.text("features.friends.content"), selection: $showsPlaylists) {
                Text(L10n.text("library.tracks")).tag(false)
                Text(L10n.text("features.playlists")).tag(true)
            }
            .pickerStyle(.menu)
            if showsPlaylists {
                ForEach(model.playlists) { playlist in
                    NavigationLink { PlaylistDetailView(playlist: playlist) } label: {
                        HStack(spacing: 12) {
                            PlaylistArtworkView(playlist: playlist, size: 52)
                                .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10))
                                .accessibilityHidden(true)
                            Text(playlist.title)
                        }
                    }
                }
            } else {
                ForEach(model.tracks) { track in
                    TrackRow(track: track, queue: model.tracks)
                }
            }
            if let error = model.error {
                Text(error).foregroundStyle(.secondary)
                Text(L10n.text("features.friends.restricted")).font(.footnote).foregroundStyle(.secondary)
            }
            if model.loading { ProgressView().frame(maxWidth: .infinity) }
            else if model.nextOffset != nil {
                Button(L10n.text(model.error == nil ? "features.load_more" : "action.retry")) { Task { await load() } }
            }
            if !model.loading && model.error == nil && model.nextOffset == nil && model.tracks.isEmpty && model.playlists.isEmpty {
                Text(L10n.text("features.friends.no_music")).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(friend.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .clearsMiniPlayer()
        .task(id: "\(sessionStore.sessionRevision)-\(showsPlaylists)") { model.reset(); await load() }
        .refreshable { model.reset(); await load() }
    }

    private func load() async {
        await model.load(environment: environment, ownerID: friend.id, playlistsOnly: showsPlaylists)
    }
}
