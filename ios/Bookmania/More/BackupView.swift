import BookmaniaCore
import SwiftUI

/// Backup and restore, compatible with Android's backup files (iOS stage 6).
struct BackupView: View {
    var body: some View {
        List {
            Text("backup_coming")
        }
        .navigationTitle("Backup and restore")
    }
}
