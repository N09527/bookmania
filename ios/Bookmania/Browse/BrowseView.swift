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
            .navigationDestination(for: LocalWork.self) { work in
                WorkView(work: work)
            }
        }
    }
}

/// Every work of the local source; the ones in the library are marked. A work is added to the library from its page.
struct LocalSourceView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var search = ""

    var body: some View {
        let works = library.works.filter {
            search.trimmed.isEmpty || $0.title.range(of: search.trimmed, options: [.caseInsensitive, .widthInsensitive]) != nil
        }
        List(works) { work in
            NavigationLink(value: work) {
                HStack(spacing: 12) {
                    CoverView(work: work).frame(width: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: work.title).lineLimit(2)
                        Text("\(work.chapters.count) books").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if library.workState(work.id).favorite {
                        Image(systemName: "heart.fill").foregroundStyle(Color.accentColor)
                            .accessibilityLabel(Text("In library"))
                    }
                }
            }
        }
        .searchable(text: $search)
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
