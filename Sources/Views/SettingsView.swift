import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Server") {
                if let server = model.api?.server {
                    LabeledContent("Connected to", value: server.name)
                    LabeledContent("Connection", value: server.isRelay ? "Relay" : (server.isLocal ? "Local network" : "Remote"))
                }
                if model.servers.count > 1 {
                    Button("Switch Server") { model.chooseAnotherServer() }
                }
            }

            Section("Account") {
                Button("Sign Out", role: .destructive) { model.signOut() }
            }

            Section("About") {
                LabeledContent("Version", value: PlexClientInfo.version)
                Text("\(PlexClientInfo.product) is an independent app and is not affiliated with, endorsed by, or sponsored by Plex, Inc. Plex is a trademark of Plex, Inc.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
