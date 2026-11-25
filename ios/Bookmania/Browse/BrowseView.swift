import BookmaniaCore
import SwiftUI

/// Browse: only the local source (online sources are Android extensions, which iOS cannot run).
struct BrowseView: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        LocalSourceView()
                    } label: {
                        Label("Local source", systemImage: "folder")
                    }
                } footer: {
                    Text("local_source_help")
                }
            }
            .navigationTitle("Browse")
        }
    }
}

struct LocalSourceView: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        List(library.works) { work in
            NavigationLink(value: work) {
                Text(work.title)
            }
        }
        .navigationDestination(for: LocalWork.self) { work in
            WorkView(work: work)
        }
        .overlay {
            if library.works.isEmpty && !library.isScanning {
                ContentUnavailableView {
                    Label("No books yet", systemImage: "folder")
                } description: {
                    Text("local_source_help")
                }
            }
        }
        .navigationTitle("Local source")
        .refreshable { library.refresh() }
    }
}
