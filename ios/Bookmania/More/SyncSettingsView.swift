import SwiftUI

/// The WebDAV sync (More › WebDAV sync), as on Android (SettingsSyncScreen): the server and account, whether to sync
/// and the book files, sync now and the outcome of the last syncs.
struct SyncSettingsView: View {
    @ObservedObject private var sync = SyncService.shared
    @State private var url = SyncService.shared.serverURL
    @State private var user = SyncService.shared.user
    @State private var password = SyncKeychain.password() ?? ""
    @State private var enabled = SyncService.shared.isEnabled
    @State private var files = SyncService.shared.syncsFiles
    @State private var wifiOnly = SyncService.shared.filesOnWiFiOnly
    @State private var testing = false
    @State private var message: String?

    private var isHTTPS: Bool { url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("https://") }

    var body: some View {
        Form {
            Section {
                TextField("Address (https://…)", text: $url)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Account", text: $user)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                HStack {
                    Button("Test", action: test)
                    Spacer()
                    if testing { ProgressView() }
                    Spacer()
                    Button("Save", action: save)
                }
                .buttonStyle(.borderless)
                .disabled(testing)
            } header: {
                Text("WebDAV server")
            } footer: {
                Text("sync_account_help")
            }
            Section {
                Toggle("Sync with this server", isOn: Binding(get: { enabled }, set: {
                    enabled = $0
                    sync.setEnabled($0)
                }))
                .disabled(sync.serverURL.isEmpty)
                Toggle(isOn: Binding(get: { files }, set: {
                    files = $0
                    sync.setSyncsFiles($0)
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sync book files")
                        Text("sync_files_help").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Book files only on Wi-Fi", isOn: Binding(get: { wifiOnly }, set: {
                    wifiOnly = $0
                    sync.setFilesOnWiFiOnly($0)
                }))
            }
            Section {
                Button {
                    Task { await sync.syncLibrary() }
                } label: {
                    HStack {
                        Text("Sync now")
                        if sync.isSyncing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!sync.isConfigured || sync.isSyncing)
                ForEach(statusLines, id: \.self) { line in
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("sync_info")
            }
        }
        .navigationTitle("WebDAV sync")
        .alert(Text("WebDAV sync"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("Done") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private var statusLines: [String] {
        var lines: [String] = []
        if let error = sync.lastError {
            lines.append(String(format: NSLocalizedString("sync_last_error", comment: ""), error))
        } else if let last = sync.lastSync {
            lines.append(String(format: NSLocalizedString("sync_last", comment: ""), last.formatted(.relative(presentation: .named))))
        } else {
            lines.append(NSLocalizedString("sync_never", comment: ""))
        }
        if !sync.conflicts.isEmpty {
            lines.append(String(format: NSLocalizedString("sync_conflicts", comment: ""), sync.conflicts.joined(separator: "、")))
        }
        if let first = sync.fileProblems.first {
            lines.append(String(format: NSLocalizedString("sync_file_problems", comment: ""), sync.fileProblems.count, first))
        }
        return lines
    }

    private func test() {
        guard isHTTPS else {
            message = NSLocalizedString("sync_https_only", comment: "")
            return
        }
        testing = true
        Task {
            let problem = await sync.test(url: url, user: user, password: password)
            testing = false
            message = problem.map { String(format: NSLocalizedString("sync_test_failed", comment: ""), $0) }
                ?? NSLocalizedString("sync_test_ok", comment: "")
        }
    }

    private func save() {
        guard isHTTPS else {
            message = NSLocalizedString("sync_https_only", comment: "")
            return
        }
        let saved = sync.saveAccount(url: url, user: user, password: password)
        url = sync.serverURL
        message = saved ? NSLocalizedString("Saved.", comment: "") : NSLocalizedString("sync_keychain_failed", comment: "")
    }
}
