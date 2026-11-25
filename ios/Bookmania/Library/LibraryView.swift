import BookmaniaCore
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryModel

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 16)]

    var body: some View {
        NavigationStack {
            Group {
                if library.works.isEmpty && !library.isScanning {
                    ContentUnavailableView {
                        Label("No books yet", systemImage: "books.vertical")
                    } description: {
                        Text("local_source_help")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(library.works) { work in
                                NavigationLink(value: work) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        CoverView(work: work)
                                        Text(work.title)
                                            .font(.subheadline)
                                            .lineLimit(2)
                                            .foregroundStyle(.primary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: LocalWork.self) { work in
                WorkView(work: work)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        library.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            .refreshable { library.refresh() }
        }
    }
}
