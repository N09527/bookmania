import Darwin
import SwiftUI

/// A test of the extension runtime (docs/extensions-and-sync/design.md, E-1): whether this build contains the
/// embedded Java VM, and starting it with the extension host, which then answers `host.hello`. No extension is
/// installed or run here.
struct ExtensionRuntimeView: View {
    @State private var busy = false
    @State private var lines: [String] = []
    private let included = ExtensionRuntime.shared.isIncluded

    var body: some View {
        List {
            Section {
                LabeledContent("Included in this build", value: NSLocalizedString(included ? "Yes" : "No", comment: ""))
                Button {
                    Task { await startAndSayHello() }
                } label: {
                    HStack {
                        Text("Start and say hello")
                        if busy {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!included || busy)
            } footer: {
                Text("extension_runtime_help")
            }
            if !lines.isEmpty {
                Section("Result") {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.footnote.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Extension runtime")
    }

    private func startAndSayHello() async {
        busy = true
        defer { busy = false }
        lines = []
        let runtime = ExtensionRuntime.shared
        let before = memoryFootprintMB()
        let started = Date()
        do {
            try await runtime.start()
            let ready = Date()
            lines.append(String(format: NSLocalizedString("extension_runtime_started", comment: ""), ready.timeIntervalSince(started)))
            let reply = try await runtime.call("host.hello")
            lines.append(String(format: NSLocalizedString("extension_runtime_hello", comment: ""), Date().timeIntervalSince(ready)))
            lines.append(Self.pretty(reply))
            lines.append(String(format: NSLocalizedString("extension_runtime_memory", comment: ""), before, memoryFootprintMB()))
        } catch {
            lines.append(error.localizedDescription)
        }
    }

    private static func pretty(_ json: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: json),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return String(decoding: json, as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The app's physical memory footprint in MB: what iOS counts against an app's memory limit.
func memoryFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}
