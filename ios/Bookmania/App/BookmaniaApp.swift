import BookmaniaCore
import SwiftUI

@main
struct BookmaniaApp: App {
    @StateObject private var library = LibraryModel()
    @StateObject private var reader = ReaderPresenter()
    /// The app's appearance: 0 as the system, 1 light, 2 dark.
    @AppStorage(AppSettingsKeys.theme) private var theme = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(reader)
                .preferredColorScheme(theme == 1 ? .light : theme == 2 ? .dark : nil)
                .task {
                    library.refresh()
                    SyncService.shared.start()
                }
                .fullScreenCover(item: $reader.chapter, onDismiss: { reader.closed() }) { chapter in
                    ReaderScreen(chapter: chapter) { reader.chapter = nil }
                        .ignoresSafeArea()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: library.refresh() // books may have been added in the Files app
            case .background: AppEnvironment.shared.library.flush()
            default: break
            }
        }
    }
}

/// Opens the reader for a chapter, from any tab.
@MainActor
final class ReaderPresenter: ObservableObject {
    @Published var chapter: LocalChapter?
    private var opened: LocalChapter?

    func open(_ chapter: LocalChapter) {
        opened = chapter
        self.chapter = chapter
    }

    /// The reader is gone (it saved its position as it closed): the work's progress goes to the WebDAV sync.
    func closed() {
        if let opened { SyncService.shared.pushAfterReading(opened) }
        opened = nil
    }
}

/// Keys of the iOS version's own settings (no Android counterpart).
enum AppSettingsKeys {
    static let theme = "bookmania_ios_theme"
}
