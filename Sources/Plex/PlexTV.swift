import Foundation

struct PlexPin: Decodable {
    let id: Int
    let code: String
    let authToken: String?
}

struct PlexResource: Decodable, Identifiable, Hashable {
    let name: String
    let product: String?
    let productVersion: String?
    let clientIdentifier: String
    let provides: String?
    let owned: Bool?
    let accessToken: String?
    let presence: Bool?
    let connections: [PlexConnection]?

    var id: String { clientIdentifier }
    var isServer: Bool { (provides ?? "").split(separator: ",").contains("server") }

    static func == (a: PlexResource, b: PlexResource) -> Bool { a.clientIdentifier == b.clientIdentifier }
    func hash(into hasher: inout Hasher) { hasher.combine(clientIdentifier) }
}

struct PlexConnection: Decodable, Hashable {
    let `protocol`: String?
    let address: String?
    let port: Int?
    let uri: String
    let local: Bool?
    let relay: Bool?
    let IPv6: Bool?
}

/// plex.tv account APIs: PIN sign-in and resource (server) discovery.
enum PlexTV {
    private static let base = URL(string: "https://plex.tv/api/v2")!

    static func createPin() async throws -> PlexPin {
        let url = URL(string: "https://plex.tv/api/v2/pins?strong=true")!
        return try await HTTP.decode(PlexPin.self, from: url, method: "POST", token: nil)
    }

    static func checkPin(_ id: Int) async throws -> PlexPin {
        let url = base.appending(path: "pins/\(id)")
        return try await HTTP.decode(PlexPin.self, from: url, token: nil)
    }

    /// The web page where the user approves this device.
    static func authURL(for pin: PlexPin) -> URL {
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        }
        let fragment = "?clientID=\(enc(PlexClientInfo.identifier))"
            + "&code=\(enc(pin.code))"
            + "&context%5Bdevice%5D%5Bproduct%5D=\(enc(PlexClientInfo.product))"
            + "&context%5Bdevice%5D%5Bplatform%5D=\(enc(PlexClientInfo.platform))"
            + "&context%5Bdevice%5D%5Bdevice%5D=\(enc(PlexClientInfo.device))"
        return URL(string: "https://app.plex.tv/auth#" + fragment)!
    }

    static func resources(token: String) async throws -> [PlexResource] {
        let url = URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")!
        return try await HTTP.decode([PlexResource].self, from: url, token: token)
    }
}

/// Finds the best working connection for a server: local first, then remote, then relay.
enum ServerConnector {
    static func connect(to resource: PlexResource, fallbackToken: String) async throws -> PlexServer {
        let token = resource.accessToken ?? fallbackToken
        let all = resource.connections ?? []
        let local = all.filter { $0.local == true && $0.relay != true }
        let remote = all.filter { $0.local != true && $0.relay != true }
        let relay = all.filter { $0.relay == true }

        for (group, timeout) in [(local, 3.0), (remote, 6.0), (relay, 10.0)] where !group.isEmpty {
            if let (url, conn) = await firstReachable(group, token: token, timeout: timeout) {
                return PlexServer(
                    id: resource.clientIdentifier,
                    name: resource.name,
                    baseURL: url,
                    token: token,
                    isLocal: conn.local == true,
                    isRelay: conn.relay == true
                )
            }
        }
        throw PlexError.unreachable(resource.name)
    }

    private static func firstReachable(_ connections: [PlexConnection], token: String, timeout: TimeInterval) async -> (URL, PlexConnection)? {
        await withTaskGroup(of: (URL, PlexConnection)?.self) { group in
            for conn in connections {
                group.addTask {
                    guard let url = URL(string: conn.uri) else { return nil }
                    do {
                        _ = try await HTTP.data(url.appending(path: "identity"), token: token, timeout: timeout)
                        return (url, conn)
                    } catch {
                        return nil
                    }
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }
}
