import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .launching:
            ProgressView()
        case .signedOut:
            SignInView()
        case .discovering:
            StatusView(title: "Finding your servers…")
        case .connecting(let name):
            StatusView(title: "Connecting to \(name)…")
        case .pickServer:
            ServerPickerView()
        case .ready:
            MainTabView()
        case .failed(let message):
            ContentUnavailableView {
                Label("Something went wrong", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.discoverServers() } }
                    .buttonStyle(.borderedProminent)
                if model.servers.count > 1 {
                    Button("Choose Another Server") { model.chooseAnotherServer() }
                }
                Button("Sign Out", role: .destructive) { model.signOut() }
            }
        }
    }
}

private struct StatusView: View {
    let title: String
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
            Text(title).font(.title3).foregroundStyle(.secondary)
        }
    }
}

struct ServerPickerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List(model.servers) { server in
                Button {
                    Task { await model.connect(to: server) }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "server.rack")
                            .font(.title2)
                            .frame(width: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(server.name).font(.headline)
                            Text(server.owned == true ? "Your server" : "Shared with you")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if server.presence == false {
                            Text("Offline").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("Choose a Server")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign Out") { model.signOut() }
                }
            }
        }
    }
}
