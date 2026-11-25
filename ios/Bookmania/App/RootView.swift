import SwiftUI

/// The four tabs of the Android version: Library, Recents, Browse, More.
struct RootView: View {
    var body: some View {
        TabView {
            Tab("Library", systemImage: "books.vertical") {
                LibraryView()
            }
            Tab("Recents", systemImage: "clock") {
                RecentsView()
            }
            Tab("Browse", systemImage: "safari") {
                BrowseView()
            }
            Tab("More", systemImage: "ellipsis.circle") {
                MoreView()
            }
        }
    }
}
