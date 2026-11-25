import BookmaniaCore
import SwiftUI
import UIKit

/// A work's cover (`cover.jpg` in its folder), or a placeholder.
struct CoverView: View {
    let work: LocalWork
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(uiColor: .secondarySystemBackground))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "book.closed")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: work.id) {
            if let url = work.coverFile {
                image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path) }.value
            } else if let bytes = await BookInfoCache.shared.cover(for: work) {
                // No cover.jpg: the cover of the first book, as Android does.
                image = UIImage(data: Data(bytes))
            }
        }
    }
}
