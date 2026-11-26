import BookmaniaCore
import SwiftUI

/// The library: the works added to it, under their categories (collapsible), sorted and filtered as set in the
/// options; a search over titles, authors, artists and genres.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var search = ""
    @State private var showOptions = false
    @State private var showCategories = false
    @State private var collapsed: Set<Int64> = []

    private var layout: Int { library.preferences.layout }
    private var badge: Int { library.preferences.unreadBadge }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library")
                .navigationDestination(for: LocalWork.self) { work in
                    WorkView(work: work)
                }
                .searchable(text: $search, prompt: Text("Search the library"))
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            showOptions = true
                        } label: {
                            Label("Sort and filter", systemImage: library.preferences.options.hasFilters
                                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        }
                        Menu {
                            Button {
                                showCategories = true
                            } label: {
                                Label("Edit categories", systemImage: "tag")
                            }
                            Button {
                                library.refresh()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                    }
                }
                .refreshable { library.refresh() }
                .sheet(isPresented: $showOptions) {
                    LibraryOptionsView().environmentObject(library)
                }
                .sheet(isPresented: $showCategories) {
                    NavigationStack { CategoriesView() }.environmentObject(library)
                }
                .onAppear { collapsed = library.preferences.collapsedCategories }
        }
    }

    @ViewBuilder private var content: some View {
        let _ = library.optionsVersion // read again when the options change
        let sections = library.sections(search: search)
        let empty = sections.allSatisfy { $0.items.isEmpty }
        if empty && !library.isScanning {
            if !search.isEmpty || library.preferences.options.hasFilters {
                ContentUnavailableView.search(text: search)
            } else {
                ContentUnavailableView {
                    Label("Your library is empty", systemImage: "books.vertical")
                } description: {
                    Text("library_empty_help")
                }
            }
        } else if layout == 0 {
            List {
                ForEach(sections) { section in
                    Section {
                        if !collapsed.contains(section.id) {
                            ForEach(section.items) { item in
                                NavigationLink(value: item.work) {
                                    WorkListCell(item: item, badge: badge)
                                }
                            }
                        }
                    } header: {
                        if showHeaders(sections) { header(section) }
                    }
                }
            }
            .listStyle(.plain)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: []) {
                    ForEach(sections) { section in
                        if showHeaders(sections) { header(section).padding(.horizontal) }
                        if !collapsed.contains(section.id) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 16)], spacing: 20) {
                                ForEach(section.items) { item in
                                    NavigationLink(value: item.work) {
                                        WorkGridCell(item: item, layout: layout, badge: badge)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
        }
    }

    /// Headers only when there are categories (a single default section needs none).
    private func showHeaders(_ sections: [LibrarySection]) -> Bool {
        sections.count > 1 || sections.first?.category != nil
    }

    private func header(_ section: LibrarySection) -> some View {
        Button {
            if collapsed.contains(section.id) { collapsed.remove(section.id) } else { collapsed.insert(section.id) }
            library.preferences.collapsedCategories = collapsed
        } label: {
            HStack {
                Image(systemName: collapsed.contains(section.id) ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                Text(verbatim: section.category?.name ?? NSLocalizedString("Default category", comment: ""))
                    .font(.headline)
                Text(verbatim: "\(section.items.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Sort, filters and display of the library (FilterBottomSheet and the display options on Android).
struct LibraryOptionsView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss

    private var prefs: LibraryPreferences { library.preferences }

    var body: some View {
        NavigationStack {
            Form {
                Section("Filter") {
                    Picker("Unread", selection: binding(\.filterUnread)) {
                        Text("Off").tag(0)
                        Text("Unread").tag(1)
                        Text("Read").tag(2)
                        Text("Not started").tag(3)
                        Text("In progress").tag(4)
                    }
                    Picker("Completed", selection: binding(\.filterCompleted)) {
                        Text("Off").tag(0)
                        Text("Completed").tag(1)
                        Text("Not completed").tag(2)
                    }
                    Picker("Bookmarked", selection: binding(\.filterBookmarked)) {
                        Text("Off").tag(0)
                        Text("Bookmarked").tag(1)
                        Text("Not bookmarked").tag(2)
                    }
                }
                Section("Sort") {
                    Picker("Sort by", selection: binding(\.sortingMode)) {
                        Text("Title").tag(0)
                        Text("Last read").tag(1)
                        Text("Latest chapter").tag(2)
                        Text("Unread").tag(3)
                        Text("Total chapters").tag(4)
                        Text("Date added").tag(5)
                        Text("Date fetched").tag(6)
                    }
                    Picker("Order", selection: binding(\.sortingAscending)) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Display") {
                    Picker("Display as", selection: binding(\.layout)) {
                        Text("List").tag(0)
                        Text("Compact grid").tag(1)
                        Text("Comfortable grid").tag(2)
                        Text("Cover only grid").tag(3)
                    }
                    Picker("Unread badges", selection: binding(\.unreadBadge)) {
                        Text("Hide").tag(0)
                        Text("Dot").tag(1)
                        Text("Number").tag(2)
                    }
                }
            }
            .navigationTitle(Text("Sort and filter"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func binding<T>(_ path: ReferenceWritableKeyPath<LibraryPreferences, T>) -> Binding<T> {
        Binding(get: { prefs[keyPath: path] }, set: {
            prefs[keyPath: path] = $0
            library.optionsVersion += 1
        })
    }
}

/// The library's categories: add, rename, delete, reorder.
struct CategoriesView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: LibraryCategory?
    @State private var name = ""
    @State private var adding = false

    var body: some View {
        List {
            ForEach(library.categories) { category in
                Button {
                    editing = category
                    name = category.name
                } label: {
                    Text(verbatim: category.name).foregroundStyle(.primary)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        library.env.library.deleteCategory(category.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onMove { from, to in
                var ids = library.categories.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                library.env.library.reorderCategories(ids)
            }
        }
        .overlay {
            if library.categories.isEmpty {
                ContentUnavailableView {
                    Label("No categories", systemImage: "tag")
                } description: {
                    Text("categories_help")
                }
            }
        }
        .navigationTitle(Text("Edit categories"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    name = ""
                    adding = true
                } label: {
                    Label("Add category", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .bottomBar) { EditButton() }
        }
        .alert(Text("Add category"), isPresented: $adding) {
            TextField(text: $name) { Text("Name") }
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let trimmed = name.trimmed
                if !trimmed.isEmpty { library.env.library.addCategory(trimmed) }
            }
        }
        .alert(Text("Rename category"), isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField(text: $name) { Text("Name") }
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let trimmed = name.trimmed
                if let editing, !trimmed.isEmpty { library.env.library.renameCategory(editing.id, trimmed) }
            }
        }
    }
}

/// Which categories a work is in (shown when adding it to the library, and from the work page).
struct CategoryPickerView: View {
    let work: LocalWork
    let adding: Bool
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int64> = []

    var body: some View {
        NavigationStack {
            List(library.categories) { category in
                Button {
                    if selected.contains(category.id) { selected.remove(category.id) } else { selected.insert(category.id) }
                } label: {
                    HStack {
                        Text(verbatim: category.name).foregroundStyle(.primary)
                        Spacer()
                        if selected.contains(category.id) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                }
            }
            .navigationTitle(Text("Set categories"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(adding ? "Add" : "Done") {
                        let ids = library.categories.map(\.id).filter(selected.contains)
                        if adding { library.addToLibrary(work, categories: ids) } else { library.setCategories(work, ids) }
                        dismiss()
                    }
                }
            }
            .onAppear { selected = Set(library.workState(work.id).categoryIds) }
        }
        .presentationDetents([.medium, .large])
    }
}
