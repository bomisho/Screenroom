import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    @State private var waiting = false
    @State private var error: String?
    @State private var pinURL: URL?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 88))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 10) {
                Text(PlexClientInfo.product)
                    .font(.extraLargeTitle)
                Text("Your Plex library, in a theater of your own.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            if waiting {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Approve the sign-in in the browser window, then come back here.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    HStack {
                        if let pinURL {
                            Button("Open Browser Again") { openURL(pinURL) }
                        }
                        Button("Cancel", role: .cancel) { cancel() }
                    }
                }
                .frame(maxWidth: 480)
            } else {
                Button {
                    start()
                } label: {
                    Label("Sign in with Plex", systemImage: "person.crop.circle")
                        .font(.title3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }

            if let error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            Text("Requires a Plex account and a Plex Media Server. Not affiliated with Plex, Inc.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(60)
        .onDisappear { task?.cancel() }
    }

    private func start() {
        error = nil
        waiting = true
        task = Task {
            do {
                let pin = try await PlexTV.createPin()
                let url = PlexTV.authURL(for: pin)
                pinURL = url
                openURL(url)
                // Poll for up to ~10 minutes.
                for _ in 0..<300 {
                    try await Task.sleep(for: .seconds(2))
                    let status = try await PlexTV.checkPin(pin.id)
                    if let token = status.authToken, !token.isEmpty {
                        waiting = false
                        await model.didSignIn(token: token)
                        return
                    }
                }
                error = "The sign-in request expired. Please try again."
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            waiting = false
        }
    }

    private func cancel() {
        task?.cancel()
        waiting = false
    }
}
