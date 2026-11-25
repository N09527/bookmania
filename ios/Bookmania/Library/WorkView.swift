import BookmaniaCore
import SwiftUI

/// The work page: cover, title, the description and the list of books (chapters).
struct WorkView: View {
    let work: LocalWork
    @State private var openChapter: LocalChapter?
    /// Book metadata by chapter id, read in the background.
    @State private var infos: [String: BookInfo] = [:]

    private var firstInfo: BookInfo? { work.chapters.lazy.compactMap { infos[$0.id] }.first }
    private var author: String? { work.author ?? firstInfo?.metadata.authors.first }
    private var bookDescription: String? {
        work.description ?? firstInfo?.metadata.description.map(plainText).flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    CoverView(work: work).frame(width: 110)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(work.title).font(.title3).bold()
                        if let author {
                            Text(author).foregroundStyle(.secondary)
                        }
                        Text("Local source").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .listRowSeparator(.hidden)
            }
            Section("Description") {
                if let description = bookDescription {
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
                            Text(infos[chapter.id]?.metadata.title ?? chapter.fileTitle).foregroundStyle(.primary)
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
        .task(id: work.id) {
            for chapter in work.chapters {
                if let info = await BookInfoCache.shared.info(for: chapter) { infos[chapter.id] = info }
            }
        }
        .fullScreenCover(item: $openChapter) { chapter in
            ReaderScreen(chapter: chapter) { openChapter = nil }
                .ignoresSafeArea()
        }
    }
}
