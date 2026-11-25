import SwiftUI

@main
struct BookmaniaApp: App {
    @StateObject private var library = LibraryModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .task { library.refresh() }
        }
    }
}
