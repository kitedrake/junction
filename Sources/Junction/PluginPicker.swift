import JunctionCore
import SwiftUI

/// The node whose chain the plugin picker adds to.
struct PluginPickerRequest: Identifiable {
    let node: UUID
    var id: UUID { node }
}

/// Lists the effect Audio Units installed on the Mac, by maker, with a search field; adds the chosen one to a node's
/// chain.
struct PluginPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PluginPickerRequest
    @State private var query = ""
    @State private var selection: PluginInfo.ID?

    var body: some View {
        let found = PluginCatalog.search(model.plugins, for: query)
        let vendors = Dictionary(grouping: found, by: \.vendor)
        let vendorNames = vendors.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        VStack(alignment: .leading, spacing: 14) {
            Text("Add an Audio Unit").font(.title2.weight(.semibold))
            Text("Effects installed on this Mac. A plugin runs in a process of its own where macOS allows it, and opens its own window from the inspector.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Search by name or maker", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search plugins")
            List(selection: $selection) {
                ForEach(vendorNames, id: \.self) { vendor in
                    Section(vendor) {
                        ForEach(vendors[vendor] ?? []) { plugin in
                            PluginRow(plugin: plugin)
                                .tag(plugin.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { add(plugin) }
                        }
                    }
                }
            }
            .frame(minHeight: 260)
            .overlay {
                if found.isEmpty {
                    Text(model.plugins.isEmpty ? "No effect Audio Units are installed." : "Nothing matches “\(query)”.")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("\(found.count) of \(model.plugins.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let plugin = found.first(where: { $0.id == selection }) { add(plugin) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!found.contains { $0.id == selection })
            }
        }
        .padding(22)
        .frame(width: 520, height: 520)
    }

    private func add(_ plugin: PluginInfo) {
        model.addPlugin(plugin, to: request.node)
        dismiss()
    }
}

private struct PluginRow: View {
    let plugin: PluginInfo

    var body: some View {
        HStack {
            Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
            Text(plugin.name)
            Spacer()
            if plugin.hasCustomView {
                Image(systemName: "macwindow")
                    .foregroundStyle(.secondary)
                    .help("Has a window of its own")
                    .accessibilityLabel("Has a window of its own")
            }
            if !plugin.version.isEmpty {
                Text(plugin.version).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
