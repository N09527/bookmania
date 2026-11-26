import BookmaniaCore
import SwiftUI

/// Recents (Android's recents tab): the reading history and the new chapters of the works in the library.
struct RecentsView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var reader: ReaderPresenter
    @State private var mode = 0
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if mode == 0 { history } else { updates }
            }
            .navigationTitle("Recents")
            .navigationDestination(for: LocalWork.self) { work in
                WorkView(work: work)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker(selection: $mode) {
                        Text("History").tag(0)
                        Text("Updates").tag(1)
                    } label: {
                        Text("Recents")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
                if mode == 0 && !library.history.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            confirmClear = true
                        } label: {
                            Label("Clear history", systemImage: "trash")
                        }
                    }
                }
            }
            .confirmationDialog(Text("clear_history_confirmation"), isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { library.clearHistory() }
            }
        }
    }

    @ViewBuilder private var history: some View {
        let entries = library.history
        if entries.isEmpty {
            ContentUnavailableView {
                Label("Nothing read yet", systemImage: "clock")
            } description: {
                Text("recents_help")
            }
        } else {
            List(entries) { entry in
                row(entry, date: entry.state.lastRead.map { Date(timeIntervalSince1970: Double($0) / 1000) }, progress: true)
                    .swipeActions {
                        Button(role: .destructive) {
                            library.removeFromHistory(entry.chapter)
                        } label: {
                            Label("Remove from history", systemImage: "trash")
                        }
                    }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder private var updates: some View {
        let entries = library.updates
        if entries.isEmpty {
            ContentUnavailableView {
                Label("No updates", systemImage: "sparkles")
            } description: {
                Text("updates_help")
            }
        } else {
            List(entries) { entry in
                row(entry, date: entry.state.dateFetch > 0 ? Date(timeIntervalSince1970: Double(entry.state.dateFetch) / 1000) : nil, progress: false)
            }
            .listStyle(.plain)
        }
    }

    private func row(_ entry: LibraryModel.HistoryEntry, date: Date?, progress: Bool) -> some View {
        HStack(spacing: 12) {
            NavigationLink(value: entry.work) {
                CoverView(work: entry.work).frame(width: 44)
            }
            .buttonStyle(.plain)
            Button {
                reader.open(entry.chapter)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.work.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(verbatim: entry.chapter.fileTitle)
                        .foregroundStyle(entry.state.read ? Color.secondary : Color.primary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        if let date { Text(date, format: .dateTime.year().month().day().hour().minute()) }
                        if progress && !entry.state.read && entry.state.lastPageRead > 0 {
                            Text(String(format: NSLocalizedString("Page %lld", comment: ""), entry.state.lastPageRead + 1))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
