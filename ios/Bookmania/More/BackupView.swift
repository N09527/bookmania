import BookmaniaCore
import SwiftUI
import UniformTypeIdentifiers

/// A backup file to save with the system's file exporter.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileContents: data) }
}

/// Backup and restore with Android's backup files (.tachibk): the library and its categories, the chapters' read
/// state and bookmarks, the history, the text positions and the settings move between the two versions. The book
/// files are not in backups (as on Android).
struct BackupView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var exporting = false
    @State private var importing = false
    @State private var document: BackupDocument?
    @State private var fileName = BackupMapper.fileName()
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Button {
                    createBackup()
                } label: {
                    Label("Create backup", systemImage: "square.and.arrow.up")
                }
                Button {
                    importing = true
                } label: {
                    Label("Restore backup", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("backup_help")
            }
        }
        .navigationTitle("Backup and restore")
        .fileExporter(isPresented: $exporting, document: document, contentType: .data, defaultFilename: fileName) { result in
            if case let .failure(error) = result { message = error.localizedDescription }
            document = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .item]) { result in
            switch result {
            case let .success(url): restore(url)
            case let .failure(error): message = error.localizedDescription
            }
        }
        .alert(Text("Backup and restore"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("Done") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func createBackup() {
        let env = AppEnvironment.shared
        env.library.flush()
        let backup = BackupMapper.backup(works: library.works, state: env.library.snapshot, preferences: env.preferences.all())
        document = BackupDocument(data: Data(backup.write()))
        fileName = BackupMapper.fileName()
        exporting = true
    }

    private func restore(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let backup = try AndroidBackup.read([UInt8](data))
            let env = AppEnvironment.shared
            var result = BackupMapper.RestoreResult()
            env.library.update { state in
                result = BackupMapper.restore(backup, into: &state, preferences: env.preferences)
            }
            env.library.flush()
            library.refresh()
            var lines = [String(format: NSLocalizedString("backup_restored_works", comment: ""), result.works)]
            if result.positions > 0 { lines.append(String(format: NSLocalizedString("backup_restored_positions", comment: ""), result.positions)) }
            if result.preferences > 0 { lines.append(String(format: NSLocalizedString("backup_restored_settings", comment: ""), result.preferences)) }
            if result.skipped > 0 { lines.append(String(format: NSLocalizedString("backup_skipped_sources", comment: ""), result.skipped)) }
            message = lines.joined(separator: "\n")
        } catch {
            message = NSLocalizedString("backup_invalid", comment: "")
        }
    }
}
