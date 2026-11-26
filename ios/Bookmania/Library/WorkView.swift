import BookmaniaCore
import SwiftUI

/// The work page (Android's manga details): cover, title, author, status, genres, adding to the library and its
/// categories, continue reading, the description, and the chapters (books) with their read state, bookmarks and
/// progress; sort and filters per work, as Android's chapter flags.
struct WorkView: View {
    let work: LocalWork
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var reader: ReaderPresenter
    /// Book metadata by chapter id, read in the background.
    @State private var infos: [String: BookInfo] = [:]
    @State private var pickCategories = false
    @State private var addingWithCategories = false
    @State private var confirmRemove = false

    private var current: LocalWork { library.work(work.id) ?? work }
    private var workState: WorkState { library.workState(work.id) }
    private var firstInfo: BookInfo? { current.chapters.lazy.compactMap { infos[$0.id] }.first }
    private var author: String? { current.author ?? firstInfo?.metadata.authors.first }
    private var bookDescription: String? {
        current.description ?? firstInfo?.metadata.description.map(plainText).flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        let state = library.state
        let chapters = LibraryQuery.chapters(current, flags: workState.chapterFlags, state: state)
        List {
            Section {
                header
                    .listRowSeparator(.hidden)
                actions
                    .listRowSeparator(.hidden)
            }
            if !current.genres.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(current.genres, id: \.self) { genre in
                                Text(verbatim: genre)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                            }
                        }
                    }
                }
            }
            Section("Description") {
                if let description = bookDescription {
                    Text(description)
                } else {
                    Text("No description").foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(chapters) { chapter in
                    chapterRow(chapter, state.chapters[chapter.id] ?? ChapterState())
                }
            } header: {
                HStack {
                    Text("\(current.chapters.count) books")
                    Spacer()
                    chapterOptions
                }
            }
        }
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: work.id) {
            for chapter in current.chapters {
                if let info = await BookInfoCache.shared.info(for: chapter) { infos[chapter.id] = info }
            }
        }
        .sheet(isPresented: $pickCategories) {
            CategoryPickerView(work: current, adding: addingWithCategories).environmentObject(library)
        }
        .confirmationDialog(Text("Remove from library"), isPresented: $confirmRemove) {
            Button("Remove from library", role: .destructive) { library.removeFromLibrary(current) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverView(work: current).frame(width: 110)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: current.title).font(.title3).bold()
                if let author { Text(verbatim: author).foregroundStyle(.secondary) }
                if let artist = current.artist, artist != author { Text(verbatim: artist).foregroundStyle(.secondary) }
                Text(statusText(current.status)).font(.footnote).foregroundStyle(.secondary)
                Text("Local source").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if workState.favorite {
                Button {
                    confirmRemove = true
                } label: {
                    Label("In library", systemImage: "heart.fill")
                }
                .buttonStyle(.bordered)
                if !library.categories.isEmpty {
                    Button {
                        addingWithCategories = false
                        pickCategories = true
                    } label: {
                        Label("Categories", systemImage: "tag")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    if library.categories.isEmpty {
                        library.addToLibrary(current, categories: [])
                    } else {
                        addingWithCategories = true
                        pickCategories = true
                    }
                } label: {
                    Label("Add to library", systemImage: "heart")
                }
                .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
            if let next = LibraryQuery.nextToRead(current, library.state) ?? current.chapters.first {
                let started = current.chapters.contains { library.chapterState($0.id).lastRead != nil || library.chapterState($0.id).read }
                Button {
                    reader.open(next)
                } label: {
                    Text(started ? "Continue reading" : "Start reading")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func chapterRow(_ chapter: LocalChapter, _ c: ChapterState) -> some View {
        Button {
            reader.open(chapter)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: infos[chapter.id]?.metadata.title ?? chapter.fileTitle)
                        .foregroundStyle(c.read ? Color.secondary : Color.primary)
                    HStack(spacing: 8) {
                        if let modified = chapter.modified {
                            Text(modified, style: .date)
                        }
                        if !c.read && c.lastPageRead > 0 {
                            Text(String(format: NSLocalizedString("Page %lld", comment: ""), c.lastPageRead + 1))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if c.bookmark {
                    Image(systemName: "bookmark.fill").foregroundStyle(Color.accentColor)
                        .accessibilityLabel(Text("Bookmarked"))
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                library.setBookmark([chapter], !c.bookmark)
            } label: {
                Label(c.bookmark ? "Remove bookmark" : "Bookmark", systemImage: c.bookmark ? "bookmark.slash" : "bookmark")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button {
                library.setRead([chapter], !c.read)
            } label: {
                Label(c.read ? "Mark as unread" : "Mark as read", systemImage: c.read ? "eye.slash" : "eye")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button(c.read ? "Mark as unread" : "Mark as read") { library.setRead([chapter], !c.read) }
            Button(c.bookmark ? "Remove bookmark" : "Bookmark") { library.setBookmark([chapter], !c.bookmark) }
            Button("Mark previous as read") { library.markPreviousRead(chapter, in: current) }
        }
    }

    /// Sort and filters of the chapter list (Android's chapter flags).
    private var chapterOptions: some View {
        let flags = workState.chapterFlags
        return Menu {
            Picker("Sort", selection: Binding(get: { flags & ChapterFlags.sortingMask }, set: {
                library.setChapterFlags(current, (flags & ~ChapterFlags.sortingMask) | $0)
            })) {
                Text("By source").tag(ChapterFlags.sortingSource)
                Text("By chapter number").tag(ChapterFlags.sortingNumber)
                Text("By upload date").tag(ChapterFlags.sortingUploadDate)
            }
            Picker("Order", selection: Binding(get: { flags & ChapterFlags.sortMask }, set: {
                library.setChapterFlags(current, (flags & ~ChapterFlags.sortMask) | $0)
            })) {
                Text("Descending").tag(ChapterFlags.sortDescending)
                Text("Ascending").tag(ChapterFlags.sortAscending)
            }
            Picker("Filter", selection: Binding(get: { flags & ChapterFlags.readMask }, set: {
                library.setChapterFlags(current, (flags & ~ChapterFlags.readMask) | $0)
            })) {
                Text("All").tag(0)
                Text("Unread").tag(ChapterFlags.showUnread)
                Text("Read").tag(ChapterFlags.showRead)
            }
            Picker("Bookmarks", selection: Binding(get: { flags & ChapterFlags.bookmarkedMask }, set: {
                library.setChapterFlags(current, (flags & ~ChapterFlags.bookmarkedMask) | $0)
            })) {
                Text("All").tag(0)
                Text("Bookmarked").tag(ChapterFlags.showBookmarked)
                Text("Not bookmarked").tag(ChapterFlags.showNotBookmarked)
            }
            Divider()
            Button("Mark all as read") { library.setRead(current.chapters, true) }
            Button("Mark all as unread") { library.setRead(current.chapters, false) }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
                .accessibilityLabel(Text("Sort and filter"))
        }
    }
}

/// The publishing status of a work, with Android's words.
func statusText(_ status: Int) -> LocalizedStringKey {
    switch status {
    case 1: return "Ongoing"
    case 2: return "Completed"
    case 3: return "Licensed"
    case 4: return "Publishing finished"
    case 5: return "Cancelled"
    case 6: return "On hiatus"
    default: return "Unknown status"
    }
}
