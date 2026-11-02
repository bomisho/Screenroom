import Foundation

/// Identity this app presents to plex.tv and Plex Media Servers via the `X-Plex-*` headers.
enum PlexClientInfo {
    static var product: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Theater"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static let platform = "visionOS"

    static var platformVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    static let device = "Apple Vision Pro"

    /// A stable, random identifier for this installation. Stored in the Keychain so it
    /// survives app updates; Plex uses it to recognise this device.
    static let identifier: String = {
        if let existing = Keychain.string(for: .clientIdentifier) { return existing }
        let new = UUID().uuidString
        Keychain.set(new, for: .clientIdentifier)
        return new
    }()

    /// Snapshot of the headers, safe to use from any thread.
    static let baseHeaders: [String: String] = [
        "Accept": "application/json",
        "X-Plex-Client-Identifier": identifier,
        "X-Plex-Product": product,
        "X-Plex-Version": version,
        "X-Plex-Platform": platform,
        "X-Plex-Platform-Version": platformVersion,
        "X-Plex-Device": device,
        "X-Plex-Device-Name": device,
        "X-Plex-Model": "RealityDevice",
        "X-Plex-Provides": "player",
    ]

    static func headers(token: String?) -> [String: String] {
        var h = baseHeaders
        if let token, !token.isEmpty { h["X-Plex-Token"] = token }
        return h
    }
}

enum PlexError: LocalizedError {
    case unauthorized
    case badStatus(Int)
    case invalidURL
    case noServers
    case unreachable(String)
    case notPlayable

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Your Plex sign-in has expired. Please sign in again."
        case .badStatus(let code): "The server responded with an error (\(code))."
        case .invalidURL: "Invalid address."
        case .noServers: "No Plex Media Servers were found on your account."
        case .unreachable(let name): "Couldn’t connect to “\(name)”. Make sure the server is running and reachable."
        case .notPlayable: "This item has no playable media."
        }
    }
}

/// Thin async HTTP helper used for both plex.tv and server requests.
enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func data(
        _ url: URL,
        method: String = "GET",
        token: String?,
        extraHeaders: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        for (k, v) in PlexClientInfo.headers(token: token) { request.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        if http.statusCode == 401 { throw PlexError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw PlexError.badStatus(http.statusCode) }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from url: URL, method: String = "GET", token: String?) async throws -> T {
        let data = try await data(url, method: method, token: token)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
