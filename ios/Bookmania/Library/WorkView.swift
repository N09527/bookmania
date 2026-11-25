import BookmaniaCore
import SwiftUI

/// The work page: cover, title, the description and the list of books (chapters).
struct WorkView: View {
    let work: LocalWork
    @State private var openChapter: LocalChapter?

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    CoverView(work: work).frame(width: 110)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(work.title).font(.title3).bold()
                        if let author = work.author {
                            Text(author).foregroundStyle(.secondary)
                        }
                        Text("Local source").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .listRowSeparator(.hidden)
            }
            Section("Description") {
                if let description = work.description {
                    Text(description)
                } else {
                    Text("No description").foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(work.chapters) { chapter in
                    Button {
                        openChapter = chapter
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chapter.fileTitle).foregroundStyle(.primary)
                            if let modified = chapter.modified {
                                Text(modified, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("\(work.chapters.count) books")
            }
        }
        .navigationTitle(work.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $openChapter) { chapter in
            ReaderScreen(chapter: chapter) { openChapter = nil }
                .ignoresSafeArea()
        }
    }
}
