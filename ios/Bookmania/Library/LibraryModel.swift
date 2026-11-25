import BookmaniaCore
import Foundation

/// The works of the local source. (Adding works to the library and categories come in a later stage; for now the
/// library shows every local work.)
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var works: [LocalWork] = []
    @Published private(set) var isScanning = false

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        Task.detached(priority: .userInitiated) {
            AppPaths.prepare()
            let found = LocalLibrary.scan(root: AppPaths.local)
            await MainActor.run {
                self.works = found
                self.isScanning = false
            }
        }
    }
}
