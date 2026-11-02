import SwiftUI

enum SceneID {
    static let main = "main"
    static let player = "player"
    static let theater = "theater"
}

@main
struct TheaterApp: App {
    @State private var model = AppModel()
    @State private var player = PlayerModel()

    init() {
        // Generous image cache so artwork doesn't reload while browsing.
        URLCache.shared = URLCache(memoryCapacity: 96 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup(id: SceneID.main) {
            RootView()
                .environment(model)
                .environment(player)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 1280, height: 820)

        WindowGroup(id: SceneID.player, for: PlayRequest.self) { $request in
            PlayerWindow(request: request)
                .environment(model)
                .environment(player)
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultSize(width: 1600, height: 900)

        ImmersiveSpace(id: SceneID.theater) {
            DimmedRoom()
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
