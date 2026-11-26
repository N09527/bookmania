import BookmaniaCore
import SwiftUI

/// The unread badge of a work: the number of unread chapters, or a dot (LibraryPreferences.unreadBadge).
struct UnreadBadge: View {
    let unread: Int
    let style: Int

    var body: some View {
        if unread > 0 && style > 0 {
            Group {
                if style == 1 {
                    Circle().frame(width: 10, height: 10)
                } else {
                    Text(verbatim: "\(unread)")
                        .font(.caption2.bold().monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
            }
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.accentColor))
            .accessibilityLabel(Text(String(format: NSLocalizedString("%lld unread", comment: ""), unread)))
        }
    }
}

/// A work in a grid: the cover with the badge, and the title under it (comfortable), on it (compact) or none.
struct WorkGridCell: View {
    let item: LibraryItem
    let layout: Int
    let badge: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                CoverView(work: item.work)
                if layout == 1 {
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack {
                        Spacer()
                        Text(verbatim: item.work.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                }
                UnreadBadge(unread: item.unread, style: badge).padding(6)
            }
            if layout == 2 {
                Text(verbatim: item.work.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A work in a list: a small cover, the title, the author, the badge.
struct WorkListCell: View {
    let item: LibraryItem
    let badge: Int

    var body: some View {
        HStack(spacing: 12) {
            CoverView(work: item.work).frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.work.title).lineLimit(2)
                if let author = item.work.author {
                    Text(verbatim: author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            UnreadBadge(unread: item.unread, style: badge)
        }
        .contentShape(Rectangle())
    }
}
