import Foundation
import Observation

/// Account + server session shared by every window.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case launching
        case signedOut
        case discovering
        case pickServer
        case connecting(String)
        case ready
        case failed(String)
    }

    var phase: Phase = .launching
    private(set) var userToken: String?
    private(set) var servers: [PlexResource] = []
    private(set) var api: PlexAPI?
    private(set) var libraries: [PlexDirectory] = []

    /// Incremented whenever watched state changes so lists can refresh.
    var libraryRevision = 0

    private let lastServerKey = "lastServerID"

    func bootstrap() async {
        guard case .launching = phase else { return }
        if let token = Keychain.string(for: .userToken) {
            userToken = token
            await discoverServers()
        } else {
            phase = .signedOut
        }
    }

    func didSignIn(token: String) async {
        Keychain.set(token, for: .userToken)
        userToken = token
        await discoverServers()
    }

    func discoverServers() async {
        guard let token = userToken else { phase = .signedOut; return }
        phase = .discovering
        do {
            let found = try await PlexTV.resources(token: token).filter(\.isServer)
            servers = found.sorted { ($0.owned == true ? 0 : 1, $0.name) < ($1.owned == true ? 0 : 1, $1.name) }
            guard !servers.isEmpty else { phase = .failed(PlexError.noServers.localizedDescription); return }
            if let last = UserDefaults.standard.string(forKey: lastServerKey),
               let server = servers.first(where: { $0.clientIdentifier == last }) {
                await connect(to: server)
            } else if servers.count == 1 {
                await connect(to: servers[0])
            } else {
                phase = .pickServer
            }
        } catch PlexError.unauthorized {
            signOut()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func connect(to resource: PlexResource) async {
        phase = .connecting(resource.name)
        do {
            let server = try await ServerConnector.connect(to: resource, fallbackToken: userToken ?? "")
            let api = PlexAPI(server: server)
            let libs = try await api.libraries()
            self.api = api
            self.libraries = libs.filter(\.isVideoLibrary)
            UserDefaults.standard.set(resource.clientIdentifier, forKey: lastServerKey)
            phase = .ready
        } catch {
            UserDefaults.standard.removeObject(forKey: lastServerKey)
            phase = .failed(error.localizedDescription)
        }
    }

    func chooseAnotherServer() {
        UserDefaults.standard.removeObject(forKey: lastServerKey)
        api = nil
        libraries = []
        if servers.count > 1 { phase = .pickServer } else { Task { await discoverServers() } }
    }

    func signOut() {
        Keychain.set(nil, for: .userToken)
        UserDefaults.standard.removeObject(forKey: lastServerKey)
        userToken = nil
        api = nil
        servers = []
        libraries = []
        phase = .signedOut
    }
}
