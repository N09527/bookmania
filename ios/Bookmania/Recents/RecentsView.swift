import SwiftUI

/// Recents: reading history and new chapters (a later stage).
struct RecentsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Nothing read yet", systemImage: "clock")
            } description: {
                Text("recents_help")
            }
            .navigationTitle("Recents")
        }
    }
}
