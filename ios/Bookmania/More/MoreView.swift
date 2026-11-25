import SwiftUI

struct MoreView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(name) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
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
