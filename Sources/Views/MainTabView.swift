import SwiftUI

struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                BrowseStack { HomeView() }
            }
            ForEach(model.libraries) { library in
                Tab(library.title, systemImage: library.systemImage) {
                    BrowseStack { LibraryView(library: library) }
                }
            }
            Tab("Search", systemImage: "magnifyingglass") {
                BrowseStack { SearchView() }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
            }
        }
    }
}

/// A navigation stack that knows how to open any library item.
struct BrowseStack<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(for: PlexMetadata.self) { item in
                    ItemDestination(item: item)
                }
        }
    }
}

struct ItemDestination: View {
    let item: PlexMetadata

    var body: some View {
        switch item.type {
        case "show":
            ShowView(ratingKey: item.ratingKey)
        case "season":
            ShowView(ratingKey: item.parentRatingKey ?? item.ratingKey, initialSeasonKey: item.ratingKey)
        default:
            DetailView(ratingKey: item.ratingKey)
        }
    }
}
