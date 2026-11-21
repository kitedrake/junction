import JunctionCore
import SwiftUI

/// A scene being named: a new one from the current setup, or one being renamed.
enum SceneNaming: Identifiable {
    case new
    case rename(UUID)

    var id: String {
        switch self {
        case .new: "new"
        case .rename(let id): id.uuidString
        }
    }
}

/// The scenes as menu items (the Routing menu and the menu bar extra): the current one checked, ⌃⌘1…⌃⌘9 for the
/// first nine, then saving the current setup as a new scene (not from the menu bar: its sheet needs the window).
struct SceneMenuItems: View {
    @Environment(AppModel.self) private var model
    var shortcuts = false
    var offersNew = true

    var body: some View {
        let current = model.currentScene
        Text("Scenes")
        ForEach(Array(model.graph.scenes.enumerated()), id: \.element.id) { index, scene in
            let item = Toggle(scene.name, isOn: Binding(get: { current == scene.id }, set: { _ in model.switchToScene(scene.id) }))
            if shortcuts, index < 9 {
                item.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .control])
            } else {
                item
            }
        }
        if offersNew {
            Button("New Scene from Current Setup…") { model.sceneNaming = .new }
                .disabled(model.graph.virtualDevices.isEmpty)
        }
    }
}

/// The sidebar's Scenes section: click a scene to switch to it; its context menu renames, updates or deletes it.
struct ScenesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.currentScene
        Section {
            ForEach(model.graph.scenes) { scene in
                Button {
                    model.switchToScene(scene.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: current == scene.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(current == scene.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(scene.name).lineLimit(1)
                        Spacer(minLength: 4)
                        if model.midiLearning == .scene(scene.id) {
                            Image(systemName: "pianokeys.inverse").symbolEffect(.pulse).foregroundStyle(.tint)
                                .help("Move a control on your MIDI controller to switch to this scene")
                        } else if let mapping = model.midiMapping(for: .scene(scene.id)) {
                            Image(systemName: "pianokeys").foregroundStyle(.secondary)
                                .help("MIDI: \(mapping.trigger.title)")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(current == scene.id ? "The current setup is this scene" : "Switch to \(scene.name)")
                .accessibilityValue(current == scene.id ? "Current" : "")
                .contextMenu {
                    Button("Switch to \(scene.name)") { model.switchToScene(scene.id) }
                    Button("Update from Current Setup") { model.updateScene(scene.id) }
                    Button("Rename…") { model.sceneNaming = .rename(scene.id) }
                    Divider()
                    Button(model.midiLearning == .scene(scene.id) ? "Stop MIDI Learn" : "Learn MIDI Control") {
                        model.learnMIDI(.scene(scene.id))
                    }
                    if let mapping = model.midiMapping(for: .scene(scene.id)) {
                        Button("Forget MIDI Control (\(mapping.trigger.title))") { model.removeMIDIMapping(mapping.id) }
                    }
                    Divider()
                    Button("Delete Scene", role: .destructive) { model.deleteScene(scene.id) }
                }
            }
            if model.graph.scenes.isEmpty {
                Text("Save the current setup to switch back to it later: which devices are on, their canvases and levels.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            Button {
                model.sceneNaming = .new
            } label: {
                Label("New Scene", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(model.graph.virtualDevices.isEmpty)
        } header: {
            Text("Scenes")
        }
    }
}

/// Names a new scene, or renames one.
struct SceneNameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let naming: SceneNaming
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch naming {
            case .new:
                Text("New Scene").font(.title2.weight(.semibold))
                Text("Saves which virtual devices are on, their volumes and mutes, and every canvas with its levels. Switch back to it from the Routing menu, the menu bar or the sidebar.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .rename:
                Text("Rename Scene").font(.title2.weight(.semibold))
            }
            LabeledContent("Name") { TextField("Scene", text: $name).frame(maxWidth: 240) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Save" : "Rename") {
                    switch naming {
                    case .new: model.addScene(named: name)
                    case .rename(let id): model.renameScene(id, to: name)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear {
            switch naming {
            case .new: name = Scenes.newName(in: model.graph)
            case .rename(let id): name = model.graph.scenes.first { $0.id == id }?.name ?? ""
            }
        }
    }

    private var isNew: Bool {
        if case .new = naming { return true }
        return false
    }
}
