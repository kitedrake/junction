import AppKit
import JunctionCore
import SwiftUI

/// Window › Routing Log: what the router did (built, rebuilt, failed, retried) and why, newest first.
struct LogView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        Group {
            if model.events.isEmpty {
                ContentUnavailableView("Nothing logged yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Routing events appear here: destinations starting, rebuilding, failing and trying again."))
            } else {
                List(model.events.reversed()) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(event.kind))
                            .foregroundStyle(color(event.kind))
                            .frame(width: 16)
                        Text(event.date, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(event.message)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 280)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.diagnosticReport(), forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Report", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copies a report for a bug report: versions, devices, apps, routing, this log and the setup. It names your devices and apps.")
                Button { EventLog.shared.clear() } label: { Label("Clear", systemImage: "trash") }
                    .disabled(model.events.isEmpty)
            }
        }
        .onChange(of: model.events.count) { copied = false }
    }

    private func symbol(_ kind: RoutingEvent.Kind) -> String {
        switch kind {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.octagon.fill"
        }
    }

    private func color(_ kind: RoutingEvent.Kind) -> Color {
        switch kind {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

/// Opens the Routing Log window (a view, so it can reach the openWindow action from a menu).
struct ShowLogButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Routing Log") {
            openWindow(id: "log")
            NSApp.activate()
        }
    }
}
