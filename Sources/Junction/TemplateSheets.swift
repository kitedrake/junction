import JunctionCore
import SwiftUI

/// The ready-made setups, each with its sheet.
enum TemplateKind: String, CaseIterable, Identifiable {
    case stream, podcast, dawIntoCall, callIntoDAW

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stream: "Stream Without Chat"
        case .podcast: "Podcast"
        case .dawIntoCall: "DAW into a Call"
        case .callIntoDAW: "Call into the DAW"
        }
    }
}

/// "Stream Without Chat…", "Podcast…", "DAW into a Call…", "Call into the DAW…".
struct TemplateMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(TemplateKind.allCases) { kind in
            Button("\(kind.title)…") { model.template = kind }
        }
    }
}

struct TemplateSheet: View {
    let kind: TemplateKind

    var body: some View {
        switch kind {
        case .stream: StreamTemplateSheet()
        case .podcast: PodcastTemplateSheet()
        case .dawIntoCall: DAWIntoCallSheet()
        case .callIntoDAW: CallIntoDAWSheet()
        }
    }
}

/// The frame every template sheet shares: title, explanation, device name, the choices, a hint, Cancel and Create.
private struct TemplateForm<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let summary: String
    @Binding var name: String
    let hint: String
    var canCreate = true
    let create: (String) -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            Text(summary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Device name") { TextField(title, text: $name).frame(maxWidth: 220) }
            content
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    create(name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!canCreate)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

/// Picks one app: apps using audio and the known installed ones, or any other with Choose App….
private struct AppChoice: View {
    @Environment(AppModel.self) private var model
    let label: String
    let known: [AppRef]
    let installed: [AppRef]
    var allowsNone = false
    @Binding var choice: AppRef?
    @State private var picked: [AppRef] = []

    var body: some View {
        let candidates = model.appCandidates(installed: installed, picked: picked)
        LabeledContent(label) {
            HStack {
                Picker(label, selection: $choice) {
                    if allowsNone || choice == nil { Text("None").tag(AppRef?.none) }
                    ForEach(candidates) { app in
                        Text(model.inventory.apps.contains { $0.bundleID == app.bundleID } ? "\(app.name) (using audio)" : app.name)
                            .tag(AppRef?.some(app))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                Button("Choose App…") {
                    guard let app = model.chooseApp() else { return }
                    if !picked.contains(app) { picked.append(app) }
                    choice = app
                }
            }
        }
        .onAppear {
            // Optional choices start on a known app only; required ones take any app rather than none.
            guard choice == nil else { return }
            let ids = Set(known.map(\.bundleID))
            choice = allowsNone ? candidates.first { ids.contains($0.bundleID) } : Templates.likelyApp(in: candidates, known: known)
        }
    }
}

/// Picks one microphone: the default input or one input channel of a device.
private struct MicrophoneChoice: View {
    @Environment(AppModel.self) private var model
    let label: String
    var allowsNone = false
    @Binding var choice: Templates.Microphone?

    var body: some View {
        LabeledContent(label) {
            Picker(label, selection: $choice) {
                if allowsNone { Text("None").tag(Templates.Microphone?.none) }
                ForEach(Templates.microphones(model.inventory), id: \.self) { microphone in
                    Text(microphone.title(model.inventory)).tag(Templates.Microphone?.some(microphone))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
        }
    }
}

/// "Podcast": two microphones and a call, each on its own channel pair of a recorder device.
struct PodcastTemplateSheet: View {
    @Environment(AppModel.self) private var model
    @State private var name = "Podcast"
    @State private var first: Templates.Microphone?
    @State private var second: Templates.Microphone?
    @State private var call: AppRef?

    var body: some View {
        TemplateForm(title: "Podcast",
                     summary: "Makes a virtual microphone with a channel pair for each voice: the first microphone on channels 1–2, the second on 3–4 and the call on 5–6. Record it in your recording app and every source lands on its own tracks, ready to edit separately.",
                     name: $name,
                     hint: "In your recording app, choose “\(name.isEmpty ? "Podcast" : name)” as the input and record its channels as three stereo tracks (or six mono ones).",
                     canCreate: first != nil || second != nil || call != nil,
                     create: { name in
                         let microphones = [first, second].compactMap { $0 }
                         let device = name.isEmpty ? "Podcast" : name
                         model.addTemplate("Podcast", deviceName: device) {
                             Templates.podcast(&$0, microphones: microphones, call: call, deviceName: device)
                         }
                     }) {
            MicrophoneChoice(label: "Microphone 1", allowsNone: true, choice: $first)
            MicrophoneChoice(label: "Microphone 2", allowsNone: true, choice: $second)
            AppChoice(label: "Call", known: Templates.chatApps, installed: model.installedChatApps, allowsNone: true, choice: $call)
        }
        .onAppear {
            let microphones = Templates.podcastMicrophones(model.inventory)
            first = microphones.first
            second = microphones.last
        }
    }
}

/// "DAW into a call": what the music app plays (and optionally the microphone) as the call app's microphone.
struct DAWIntoCallSheet: View {
    @Environment(AppModel.self) private var model
    @State private var name = "DAW to Call"
    @State private var daw: AppRef?
    @State private var microphone: Templates.Microphone?

    var body: some View {
        TemplateForm(title: "DAW into a Call",
                     summary: "Makes a virtual microphone that carries what your music app plays, so the people in a call hear it in full quality while you keep listening as usual. Add your microphone if you also want to talk over it.",
                     name: $name,
                     hint: "In the call app, choose “\(name.isEmpty ? "DAW to Call" : name)” as the microphone, and turn off its noise suppression and echo cancellation so music comes through.",
                     canCreate: daw != nil,
                     create: { name in
                         guard let daw else { return }
                         let device = name.isEmpty ? "DAW to Call" : name
                         model.addTemplate("DAW into a Call", deviceName: device) {
                             Templates.dawIntoCall(&$0, daw: daw, microphone: microphone, deviceName: device)
                         }
                     }) {
            AppChoice(label: "Music app", known: Templates.dawApps, installed: model.installedDAWApps, choice: $daw)
            MicrophoneChoice(label: "Microphone", allowsNone: true, choice: $microphone)
        }
    }
}

/// "Call into the DAW": the call app's audio as a microphone the music app records.
struct CallIntoDAWSheet: View {
    @Environment(AppModel.self) private var model
    @State private var name = "Call to DAW"
    @State private var call: AppRef?

    var body: some View {
        TemplateForm(title: "Call into the DAW",
                     summary: "Makes a virtual microphone that carries the call app's audio, so your music app can record the other side of a call, or play along with it, on a track of its own.",
                     name: $name,
                     hint: "In your music app, choose “\(name.isEmpty ? "Call to DAW" : name)” as the input device and record its channels 1–2 on a stereo track. You keep hearing the call as usual.",
                     canCreate: call != nil,
                     create: { name in
                         guard let call else { return }
                         let device = name.isEmpty ? "Call to DAW" : name
                         model.addTemplate("Call into the DAW", deviceName: device) {
                             Templates.callIntoDAW(&$0, call: call, deviceName: device)
                         }
                     }) {
            AppChoice(label: "Call app", known: Templates.chatApps, installed: model.installedChatApps, choice: $call)
        }
    }
}
