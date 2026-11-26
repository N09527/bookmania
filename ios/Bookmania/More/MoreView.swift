import BookmaniaCore
import SwiftUI

/// More (Android's "more" tab): incognito mode, settings, statistics, backup, about.
struct MoreView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var incognito = AppEnvironment.shared.readerPreferences.incognitoMode

    private var version: String {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(name) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: Binding(get: { incognito }, set: {
                        incognito = $0
                        AppEnvironment.shared.readerPreferences.incognitoMode = $0
                    })) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Incognito mode")
                                Text("incognito_help").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "eyeglasses")
                        }
                    }
                }
                Section {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    NavigationLink {
                        StatsView()
                    } label: {
                        Label("Statistics", systemImage: "chart.bar")
                    }
                    NavigationLink {
                        BackupView()
                    } label: {
                        Label("Backup and restore", systemImage: "arrow.up.arrow.down.circle")
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: version)
                    Link(destination: URL(string: "https://github.com/N09527/bookmania")!) {
                        Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    NavigationLink {
                        LicensesView()
                    } label: {
                        Label("Open source licenses", systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle("More")
        }
    }
}

/// Settings: the app's appearance and the readers (Android's settings for these; the typesetting is in the reader's
/// own panel).
struct SettingsView: View {
    @AppStorage(AppSettingsKeys.theme) private var theme = 0
    @State private var prefs = Prefs()

    /// The reader preferences, copied in and written back on each change.
    private struct Prefs {
        var readerTheme: Int
        var navigation: Int
        var inverted: TapNavigation.Invert
        var keepScreenOn: Bool
        var textPageTurn: String
        var textGutter: Bool
        var pagerCurl: Bool
        var pagerGutter: Bool
        var readingMode: Int
        var pageLayout: Int

        init() {
            let p = AppEnvironment.shared.readerPreferences
            readerTheme = p.readerTheme
            navigation = p.navigationModePager
            inverted = p.pagerNavInverted
            keepScreenOn = p.keepScreenOn
            textPageTurn = p.textPageTurn
            textGutter = p.textGutterShadow
            pagerCurl = p.pagerCurl
            pagerGutter = p.pagerGutterShadow
            readingMode = p.defaultReadingMode
            pageLayout = p.pageLayout
        }

        func save() {
            let p = AppEnvironment.shared.readerPreferences
            p.readerTheme = readerTheme
            p.navigationModePager = navigation
            p.pagerNavInverted = inverted
            p.keepScreenOn = keepScreenOn
            p.textPageTurn = textPageTurn
            p.textGutterShadow = textGutter
            p.pagerCurl = pagerCurl
            p.pagerGutterShadow = pagerGutter
            p.defaultReadingMode = readingMode
            p.pageLayout = pageLayout
        }
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("App theme", selection: $theme) {
                    Text("Follow system theme").tag(0)
                    Text("Light theme").tag(1)
                    Text("Dark theme").tag(2)
                }
            }
            Section("Reader") {
                Picker("Background color", selection: $prefs.readerTheme) {
                    Text("White").tag(0)
                    Text("Gray").tag(4)
                    Text("Black").tag(1)
                    Text("Automatic (by theme)").tag(2)
                }
                Picker("Tap zones", selection: $prefs.navigation) {
                    Text("Default").tag(0)
                    Text("L shaped").tag(1)
                    Text("Kindle-ish").tag(2)
                    Text("Edge").tag(3)
                    Text("Right and left").tag(4)
                    Text("Disabled").tag(5)
                }
                Picker("Invert tapping", selection: $prefs.inverted) {
                    Text("None").tag(TapNavigation.Invert.none)
                    Text("Horizontally").tag(TapNavigation.Invert.horizontal)
                    Text("Vertically").tag(TapNavigation.Invert.vertical)
                    Text("Both axes").tag(TapNavigation.Invert.both)
                }
                Toggle("Keep screen on", isOn: $prefs.keepScreenOn)
            }
            Section("Text reader") {
                Picker("Page turn animation", selection: $prefs.textPageTurn) {
                    Text("None").tag(ReaderPreferences.pageTurnNone)
                    Text("Slide").tag(ReaderPreferences.pageTurnSlide)
                    Text("Curl").tag(ReaderPreferences.pageTurnCurl)
                }
                Toggle("Gutter shadow", isOn: $prefs.textGutter)
            } footer: {
                Text("text_reader_settings_help")
            }
            Section("Image reader") {
                Picker("Reading mode", selection: $prefs.readingMode) {
                    Text("Paged (left to right)").tag(ReaderPreferences.ReadingMode.leftToRight)
                    Text("Paged (right to left)").tag(ReaderPreferences.ReadingMode.rightToLeft)
                    Text("Paged (vertical)").tag(ReaderPreferences.ReadingMode.vertical)
                    Text("Long strip").tag(ReaderPreferences.ReadingMode.webtoon)
                }
                Picker("Page layout", selection: $prefs.pageLayout) {
                    Text("Single page").tag(0)
                    Text("Double pages").tag(1)
                    Text("Automatic (based on orientation)").tag(2)
                }
                Toggle(isOn: $prefs.pagerCurl) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Page curl")
                        Text("bookmania_page_curl_summary").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $prefs.pagerGutter) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gutter shadow")
                        Text("bookmania_gutter_shadow_summary").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .onChange(of: prefsKey) { prefs.save() }
    }

    /// Everything the form edits, so one change handler writes them back.
    private var prefsKey: String {
        "\(prefs.readerTheme)|\(prefs.navigation)|\(prefs.inverted.rawValue)|\(prefs.keepScreenOn)|\(prefs.textPageTurn)|" +
            "\(prefs.textGutter)|\(prefs.pagerCurl)|\(prefs.pagerGutter)|\(prefs.readingMode)|\(prefs.pageLayout)"
    }
}

/// Statistics of the library (Android's stats screen, for what the local library has).
struct StatsView: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        let state = library.state
        let inLibrary = library.works.filter { state.works[$0.id]?.favorite == true }
        let chapters = inLibrary.flatMap(\.chapters)
        let read = chapters.filter { state.chapters[$0.id]?.read == true }.count
        let bookmarks = chapters.filter { state.chapters[$0.id]?.bookmark == true }.count
        let completed = inLibrary.filter { $0.status == 2 }.count
        let started = inLibrary.filter { w in w.chapters.contains { state.chapters[$0.id]?.read == true } }.count
        let duration = state.chapters.values.reduce(Int64(0)) { $0 + $1.readDuration }
        List {
            Section("Library") {
                LabeledContent("Works in the library", value: "\(inLibrary.count)")
                LabeledContent("Works in the local source", value: "\(library.works.count)")
                LabeledContent("Completed works", value: "\(completed)")
                LabeledContent("Works started", value: "\(started)")
            }
            Section("Chapters") {
                LabeledContent("Total chapters", value: "\(chapters.count)")
                LabeledContent("Chapters read", value: "\(read)")
                LabeledContent("Unread", value: "\(chapters.count - read)")
                LabeledContent("Bookmarked", value: "\(bookmarks)")
            }
            Section {
                LabeledContent("Read duration", value: Duration.milliseconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
            } footer: {
                Text("read_duration_info")
            }
            if !library.categories.isEmpty {
                Section("Categories") {
                    ForEach(library.categories) { category in
                        LabeledContent(category.name, value: "\(inLibrary.filter { state.works[$0.id]?.categoryIds.contains(category.id) == true }.count)")
                    }
                }
            }
        }
        .navigationTitle("Statistics")
    }
}

/// Bookmania's license and the notices of the code it includes.
struct LicensesView: View {
    private struct Notice: Identifiable {
        let id: String
        let title: String
        let text: String
    }

    private var notices: [Notice] {
        [
            Notice(id: "bookmania", title: "Bookmania (Apache License 2.0)", text: Self.resource("LICENSE")),
            Notice(id: "foliate-js", title: "foliate-js (MIT License)", text: Self.resource("NOTICE-foliate-js", ext: "txt")),
        ]
    }

    private static func resource(_ name: String, ext: String? = nil) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    var body: some View {
        List(notices) { notice in
            NavigationLink(notice.title) {
                ScrollView {
                    Text(notice.text)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .padding()
                }
                .navigationTitle(notice.title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .navigationTitle("Open source licenses")
    }
}
