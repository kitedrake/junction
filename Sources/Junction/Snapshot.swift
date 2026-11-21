import AppKit
import AVFoundation
import JunctionCore
import SwiftUI

/// A made-up setup for screenshots and demos: nothing is read from or sent to Core Audio, nothing is saved.
enum Demo {
    static let discord = AppRef(bundleID: "com.hnc.Discord", name: "Discord")
    /// Chat apps the made-up Mac has installed (screenshots never show the real Mac's apps).
    static let installedChatApps: Set<String> = ["com.hnc.Discord", "us.zoom.xos", "com.apple.FaceTime"]
    static let installedDAWApps: Set<String> = ["com.apple.logic10", "com.apple.garageband10"]
    /// Effect Audio Units the made-up Mac has installed (screenshots never show the real Mac's plugins).
    static let plugins: [PluginInfo] = [
        PluginInfo(subtype: "dely", manufacturer: "appl", name: "AUDelay", vendor: "Apple", version: "1.7.0", hasCustomView: false),
        PluginInfo(subtype: "mrev", manufacturer: "appl", name: "AUMatrixReverb", vendor: "Apple", version: "1.7.0"),
        PluginInfo(subtype: "dsrs", manufacturer: "Exmp", name: "De-Esser", vendor: "Example Audio", version: "2.1.0", hasCustomView: true),
        PluginInfo(subtype: "sprv", manufacturer: "Exmp", name: "Space Reverb", vendor: "Example Audio", version: "2.1.0", hasCustomView: true),
        PluginInfo(subtype: "tape", manufacturer: "Nwnd", name: "Tape Warmth", vendor: "Northwind Sound", version: "1.0.4", hasCustomView: true),
        PluginInfo(subtype: "clip", manufacturer: "Nwnd", name: "Soft Clipper", vendor: "Northwind Sound", version: "1.0.4"),
    ]
    /// A plugin the made-up Mac doesn't have (any more): shown as missing, with its settings kept.
    static let missingPlugin = Effect(type: "aufx", subtype: "vrdr", manufacturer: "Exmp", state: Data([0x62, 0x70, 0x6C, 0x69]),
                                      name: "Vocal Rider", vendor: "Example Audio")

    /// The made-up MIDI controller the mappings were learned from.
    static let midiController = "Desk Controller"

    @MainActor static func load(into model: AppModel) {
        let stream = VirtualDevice(name: "Stream Mix", icon: .stream)
        // A microphone only, for a recording app, with its channels named.
        let recording = VirtualDevice(name: "Recording", channels: 4, direction: .inputOnly,
                                      channelNames: ["Voice", "Voice", "Chat L", "Chat R"], icon: .microphone)
        // A speaker only, that the made-up Music app plays into: Stream Mix takes just Music from it.
        let deck = VirtualDevice(name: "DJ Deck", direction: .outputOnly, icon: .speaker)
        let music = AppRef(bundleID: "com.apple.Music", name: "Music")
        // At 44.1 kHz, so the canvas shows Stream Mix's 48 kHz being converted for them.
        let headphones = DeviceInfo(uid: "demo.headphones", name: "AirPods Pro", inputChannels: 1, outputChannels: 2,
                                    sampleRate: 44100)
        // Stream Mix: system audio without Discord, plus the mic, monitored on headphones.
        let system = Node(kind: .systemAudio(excluding: [discord]), x: 40, y: 50, canvas: stream.id)
        // The mic cleaned up before the mix (a high-pass and a gate, the gate set a little lower), and a limiter on
        // the whole stream.
        var highPass = Effect(.highPass), gate = Effect(.gate)
        highPass.set(EffectKind.highPass.parameters[0], 100)
        gate.set(EffectKind.gate.parameters[0], -48)
        let mic = Node(kind: .defaultInput, x: 40, y: 250, canvas: stream.id, effects: [highPass, gate])
        let streamNode = Node(kind: .virtualDevice(stream.id), x: 330, y: 130, canvas: stream.id,
                              effects: [Effect(.limiter)])
        let phones = Node(kind: .device(headphones.ref), x: 620, y: 130, canvas: stream.id)
        let musicThroughDeck = Node(kind: .appThroughDevice(music, device: deck.id), x: 40, y: 420, canvas: stream.id)
        let deckNode = Node(kind: .virtualDevice(deck.id), x: 330, y: 100, canvas: deck.id)
        // Recording: the mic and Discord on separate channel pairs.
        let recordingMic = Node(kind: .defaultInput, x: 40, y: 50, canvas: recording.id, effects: [missingPlugin])
        let chat = Node(kind: .application(discord), x: 40, y: 220, canvas: recording.id)
        let recordingNode = Node(kind: .virtualDevice(recording.id), x: 330, y: 100, canvas: recording.id)
        func cable(_ a: Node, _ ac: Int, _ b: Node, _ bc: Int, _ dB: Double = 0) -> Cable {
            Cable(from: PortRef(node: a.id, channel: ac), to: PortRef(node: b.id, channel: bc), gainDB: dB)
        }
        var graph = Graph(virtualDevices: [stream, recording, deck],
                          nodes: [system, mic, streamNode, phones, recordingMic, chat, recordingNode, musicThroughDeck, deckNode])
        graph.cables = [
            cable(system, 0, streamNode, 0), cable(system, 1, streamNode, 1),
            cable(mic, 0, streamNode, 0, -3), cable(mic, 0, streamNode, 1, -3),
            cable(streamNode, 0, phones, 0, -12), cable(streamNode, 1, phones, 1, -12),
            cable(recordingMic, 0, recordingNode, 0), cable(recordingMic, 0, recordingNode, 1),
            cable(chat, 0, recordingNode, 2), cable(chat, 1, recordingNode, 3),
            cable(musicThroughDeck, 0, streamNode, 0, -6), cable(musicThroughDeck, 1, streamNode, 1, -6),
        ]
        // Two scenes: everything (the current setup), and only the recorder with the mic louder.
        var recordingOnly = graph
        recordingOnly.virtualDevices[0].isEnabled = false
        if let index = recordingOnly.nodes.firstIndex(where: { $0.id == recordingMic.id }) { recordingOnly.nodes[index].gainDB = 3 }
        graph.scenes = [RoutingScene(name: "Streaming", capturing: graph),
                        RoutingScene(name: "Recording Only", capturing: recordingOnly)]
        // A made-up controller: a fader on the mic's level, a pad muting System Audio, a button bypassing the
        // gate, and program changes switching the scenes.
        let micCable = graph.cables[2]
        graph.midi = [
            MIDIMapping(target: .cableLevel(micCable.id), trigger: .controller(channel: 0, number: 7), controller: midiController),
            MIDIMapping(target: .nodeMute(system.id), trigger: .note(channel: 9, number: 36), controller: midiController),
            MIDIMapping(target: .effectBypass(gate.id), trigger: .controller(channel: 0, number: 64), controller: midiController),
            MIDIMapping(target: .scene(graph.scenes[0].id), trigger: .program(channel: 0, number: 0), controller: midiController),
            MIDIMapping(target: .scene(graph.scenes[1].id), trigger: .program(channel: 0, number: 1), controller: midiController),
        ]
        // A headphone monitor of Stream Mix on the AirPods: the mic a little quieter than in the stream, the music off.
        graph.monitors = [MonitorMix(device: stream.id, output: .device(headphones.ref), gainDB: -4,
                                     sends: [MonitorSend(node: mic.id, gainDB: -6),
                                             MonitorSend(node: musicThroughDeck.id, isOn: false)])]
        model.graph = graph
        model.showCanvas(stream.id)
        let inventory = Inventory(
            devices: [
                DeviceInfo(uid: "demo.speakers", name: "MacBook Pro Speakers", inputChannels: 0, outputChannels: 2),
                DeviceInfo(uid: "demo.mic", name: "MacBook Pro Microphone", inputChannels: 1, outputChannels: 0),
                DeviceInfo(uid: "demo.interface", name: "Scarlett 2i2 USB", inputChannels: 2, outputChannels: 2),
                headphones,
                DeviceInfo(uid: stream.uid, name: stream.name, inputChannels: 2, outputChannels: 2, isJunction: true,
                           clockDomain: 0x6A6E_6374),
                DeviceInfo(uid: recording.uid, name: recording.name, inputChannels: 4, outputChannels: 0, isJunction: true,
                           clockDomain: 0x6A6E_6374),
                DeviceInfo(uid: recording.companionUID, name: "Recording (Junction routing)", inputChannels: 0,
                           outputChannels: 4, isJunction: true, clockDomain: 0x6A6E_6374),
                DeviceInfo(uid: deck.uid, name: deck.name, inputChannels: 0, outputChannels: 2, isJunction: true,
                           clockDomain: 0x6A6E_6374),
                DeviceInfo(uid: deck.companionUID, name: "DJ Deck (Junction routing)", inputChannels: 2, outputChannels: 0,
                           isJunction: true, clockDomain: 0x6A6E_6374),
            ],
            apps: [
                AudioApp(bundleID: discord.bundleID, name: "Discord", isPlaying: true),
                AudioApp(bundleID: "com.apple.Music", name: "Music", isPlaying: true),
                AudioApp(bundleID: "com.apple.Safari", name: "Safari"),
            ],
            defaultOutputUID: "demo.speakers", defaultInputUID: "demo.mic",
            driver: .installed(version: DriverClient.bundledVersion ?? "0.2.0"),
            deviceClients: [DeviceClient(pid: 4242, bundleID: music.bundleID, deviceUID: deck.uid, app: music)])
        let running = SinkStatus(state: .running, latency: 0.0117, bufferFrames: 512)
        var streaming = running
        streaming.effectLatencies = [mic.id: 0, streamNode.id: 0]
        streaming.overloads = 0
        streaming.effectCosts = [highPass.id: EffectCost(load: 0.002, peak: 0.01, stalls: 0),
                                 gate.id: EffectCost(load: 0.001, peak: 0.004, stalls: 0)]
        var meters: [PortKey: Float] = [:]
        func meter(_ node: Node, _ output: Bool, _ values: [Float]) {
            for (channel, value) in values.enumerated() { meters[PortKey(node: node.id, isOutput: output, channel: channel)] = value }
        }
        meter(system, true, [0.42, 0.37])
        meter(musicThroughDeck, true, [0.33, 0.35])
        meter(mic, true, [0.18])
        meter(chat, true, [0.3, 0.3])
        meter(recordingMic, true, [0.18])
        meter(streamNode, false, [0.5, 0.45])
        meter(streamNode, true, [0.5, 0.45])
        meter(recordingNode, false, [0.18, 0.18, 0.3, 0.3])
        meter(phones, false, [0.12, 0.11])
        let monitorID = graph.monitors[0].id
        meters[PortKey(node: monitorID, isOutput: false, channel: 0)] = 0.28
        meters[PortKey(node: monitorID, isOutput: false, channel: 1)] = 0.26
        model.setDemoState(inventory: inventory, statuses: [streamNode.id: streaming, recordingNode.id: running, phones.id: running,
                                                            monitorID: running],
                           meters: meters)
        model.selection = .node(system.id)
        // Settings as a released build shows them before the driver installer is allowed: crash reports on.
        model.setDemoDriverInstaller(.requiresApproval, offersCrashReports: true)
        model.setDemoMIDI(learning: nil, sources: [midiController])
        EventLog.shared.add(.info, "Stream Mix: started. 4 cables, System Audio leaves out 3 processes, buffer 512 frames, about 12 ms")
        EventLog.shared.add(.error, "AirPods Pro: Couldn't combine the devices (the device went away). Attempt 1; trying again in 2 s.")
        EventLog.shared.add(.info, "AirPods Pro: started. 2 cables, buffer 512 frames, about 9 ms")
        EventLog.shared.add(.info, "Recording: started. 4 cables, Discord captures 4 processes, buffer 512 frames, about 12 ms")
    }
}

extension Demo {
    /// A made-up crash of Junction Helper, offered as a released build would (with a report address).
    @MainActor static func crashOffer(_ model: AppModel) -> CrashOffer {
        let header = #"{"app_name":"JunctionHelper","timestamp":"2026-11-20 10:15:02.00 +0100","app_version":"0.9.0","bundleID":"local.junction.helper","bug_type":"309","os_version":"macOS 26.1 (25B78)","name":"JunctionHelper"}"#
        let body = """
        {
          "procName" : "JunctionHelper",
          "procPath" : "/Applications/Junction.app/Contents/Library/LoginItems/JunctionHelper.app/Contents/MacOS/JunctionHelper",
          "exception" : {"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
          "faultingThread" : 0,
          "threads" : [{"triggered":true,"queue":"com.apple.main-thread","frames":[{"symbol":"RoutingService.replan(force:)"}]}]
        }
        """
        let file = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports/JunctionHelper-2026-11-20-101502.ips")
        let crashes = CrashReports.parse(header + "\n" + body, file: file, modified: Date()).map { [$0] } ?? []
        return CrashOffer(report: CrashReports.compose(diagnostic: model.diagnosticReport(), crashes: crashes), crashes: crashes,
                          destination: URL(string: "https://example.com/junction/crash-report"))
    }
}

/// Development aid: `JUNCTION_SNAPSHOT=<folder>` loads the demo setup, saves PNGs of the main states, each as
/// `<state>-light.png` and `<state>-dark.png`, into the folder and quits. Needs Screen Recording permission for the terminal that launches it.
enum Snapshot {
    static func runIfRequested(_ model: AppModel) {
        guard let folder = ProcessInfo.processInfo.environment["JUNCTION_SNAPSHOT"].map({ URL(fileURLWithPath: $0, isDirectory: true) })
        else { return }
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            /// Saves the current state in both appearances (light first, dark last, so the next state starts dark).
            @MainActor func both(_ name: String, sheet: Bool = false) async {
                for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    try? await Task.sleep(for: .milliseconds(800))
                    if sheet { captureSheet(folder, "\(name)-\(suffix)") } else { capture(folder, "\(name)-\(suffix)") }
                }
            }
            NSApp.activate()
            NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
            resize(1440, 810)
            try? await Task.sleep(for: .seconds(1))
            await both("canvas")  // System Audio selected: the apps it leaves out

            if let stream = model.canvas.flatMap(model.graph.deviceNode) { model.selection = .node(stream.id) }
            await both("device")
            // The mic's effect chain: a high-pass filter and a noise gate before the mix, meters after them.
            if let mic = model.canvasNodes.first(where: { !$0.effects.isEmpty && $0.kind == .defaultInput }) {
                model.selection = .node(mic.id)
            }
            await both("effects")
            // MIDI learn waiting for a control for the mic's mute.
            if let mic = model.canvasNodes.first(where: { !$0.effects.isEmpty && $0.kind == .defaultInput }) {
                model.setDemoMIDI(learning: .nodeMute(mic.id), sources: [Demo.midiController])
                await both("midi-learn")
                model.setDemoMIDI(learning: nil, sources: [Demo.midiController])
            }
            // Settings listing the made-up controller's mappings.
            await captureSettings(folder, "midi-settings")
            // The plugin picker, listing the made-up Mac's effect Audio Units.
            if let mic = model.canvasNodes.first(where: { !$0.effects.isEmpty && $0.kind == .defaultInput }) {
                model.showPluginPicker(for: mic.id)
                try? await Task.sleep(for: .milliseconds(600))
                await both("plugin-picker", sheet: true)
                model.pluginPicker = nil
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let cable = model.canvasCables.first(where: { $0.gainDB < 0 }) { model.selection = .cable(cable.id) }
            await both("cable")
            // Several nodes picked with a drag box: the selection inspector.
            model.selection = Selection.of(Set(model.canvasNodes.filter { $0.x < CanvasColumn.device }.map(\.id)))
            await both("multi-select")
            // Zoomed in on the device and the headphones, the minimap showing where that is.
            model.selection = nil
            model.showMinimap = true
            if let stream = model.canvas.flatMap(model.graph.deviceNode) {
                let center = CGPoint(x: stream.x + CanvasMetrics.nodeWidth + 60, y: stream.y + 80)
                model.viewport = CanvasViewport(scale: 1.5).centered(on: center, viewSize: model.canvasViewSize)
            }
            await both("zoomed")
            model.zoomToActualSize()
            model.viewport = CanvasViewport()
            // The mixer of the same canvas, the mic soloed on the headphone monitor.
            model.showsMixer = true
            if let mic = model.mixerStrips.first(where: { model.node($0.node)?.kind == .defaultInput }) {
                model.selection = .node(mic.node)
                model.toggleSolo(mic)
            }
            await both("mixer")
            resize(980, 560)
            await both("mixer-minimum-size")
            resize(1440, 810)
            model.clearListening()
            model.showsMixer = false
            model.selection = nil
            if let first = model.canvas, let other = model.graph.virtualDevices.first(where: { $0.id != first }) {
                model.showCanvas(other.id)
                await both("second-canvas")
                // A plugin that isn't installed: passed through, its settings kept.
                if let mic = model.canvasNodes.first(where: { $0.effects.contains(Demo.missingPlugin) }) {
                    model.selection = .node(mic.id)
                    await both("missing-plugin")
                    model.selection = nil
                }
                model.showCanvas(first)
            }
            // The Routing menu open on its scenes (the sidebar lists them too).
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                NSApp.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(for: .milliseconds(800))
                captureMenu("Routing", folder, "scene-menu-\(suffix)")
            }

            let demoInventory = model.inventory, demoStatuses = model.statuses, demoMeters = model.meters
            var outdated = demoInventory
            outdated.driver = .installed(version: "0.1.0")  // older than any bundled driver
            model.selection = nil
            model.setDemoState(inventory: outdated, statuses: demoStatuses, meters: demoMeters)
            await both("driver-update")
            model.setDemoState(inventory: demoInventory, statuses: demoStatuses, meters: demoMeters)
            model.setDemoMicrophoneAccess(.denied)
            await both("no-microphone")  // the banner asking to allow audio inputs
            model.setDemoMicrophoneAccess(.authorized)
            // After a crash, with crash reports on: the whole report, before anything is sent.
            model.setDemoCrashOffer(Demo.crashOffer(model))
            try? await Task.sleep(for: .milliseconds(600))
            await both("crash-report", sheet: true)
            model.setDemoCrashOffer(nil)
            try? await Task.sleep(for: .milliseconds(500))

            model.graph = Graph()
            model.selection = nil
            model.setDemoState(inventory: model.inventory, statuses: [:], meters: [:])
            await both("empty")

            for (kind, name) in [(TemplateKind.stream, "stream-template"), (.podcast, "podcast-template"),
                                 (.dawIntoCall, "daw-into-call-template"), (.callIntoDAW, "call-into-daw-template")] {
                model.template = kind
                try? await Task.sleep(for: .milliseconds(600))
                await both(name, sheet: true)
                model.template = nil
                try? await Task.sleep(for: .milliseconds(500))
            }

            model.addVirtualDevice()
            await both("new-device")  // a canvas with only its device: the hint

            model.graph = Graph()
            model.setDemoState(inventory: Inventory(), statuses: [:], meters: [:])
            model.addStreamWithoutChat(excluding: [Demo.discord], deviceName: "Stream Mix")
            await both("no-driver")

            model.setDemoMIDI(learning: nil, sources: [])
            await captureSettings(folder, "settings")

            if let routing = NSApp.mainMenu?.items.first(where: { $0.title == "Routing" })?.submenu,
               let index = routing.items.firstIndex(where: { $0.title == "Show Routing Log" }) {
                routing.performActionForItem(at: index)
                try? await Task.sleep(for: .milliseconds(800))
            }
            if let log = NSApp.windows.first(where: { $0.isVisible && $0.title == "Routing Log" }) {
                for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    try? await Task.sleep(for: .milliseconds(600))
                    screencapture(["-x", "-o", "-l", "\(log.windowNumber)"], folder, "log-\(suffix)")
                }
                log.close()
            } else {
                FileHandle.standardError.write(Data("Couldn't open the Routing Log for a screenshot.\n".utf8))
            }
            NSApp.windows.first { $0.isVisible && $0.contentView != nil }?.makeKeyAndOrderFront(nil)
            resize(980, 560)
            await both("minimum-size")
            NSApp.terminate(nil)
        }
    }

    /// Opens Settings, captures it in both appearances as `<name>-light.png` and `<name>-dark.png`, and closes it.
    @MainActor static func captureSettings(_ folder: URL, _ name: String) async {
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let index = appMenu.items.firstIndex(where: { $0.title.hasPrefix("Settings") }) {
            appMenu.performActionForItem(at: index)
        }
        try? await Task.sleep(for: .milliseconds(800))
        if let settings = NSApp.windows.first(where: { $0.isVisible && $0 != mainWindow && $0.contentView != nil
            && ($0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") ?? false) }) {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                NSApp.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(for: .milliseconds(600))
                screencapture(["-x", "-o", "-l", "\(settings.windowNumber)"], folder, "\(name)-\(suffix)")
            }
            settings.close()
        } else {
            let windows = NSApp.windows.map { "\($0.title)|\($0.identifier?.rawValue ?? "-")|\($0.isVisible)" }
            FileHandle.standardError.write(Data("Couldn't open the Settings window for a screenshot: \(windows)\n".utf8))
        }
        NSApp.windows.first { $0.isVisible && $0.contentView != nil }?.makeKeyAndOrderFront(nil)
    }

    @MainActor static func resize(_ width: CGFloat, _ height: CGFloat) {
        guard let window = mainWindow else { return }
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: width, height: height)
        window.setFrame(frame, display: true)
    }

    @MainActor static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.title == "Junction" }
            ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil }
    }

    @MainActor static func capture(_ folder: URL, _ name: String) {
        guard let window = mainWindow else { return }
        screencapture(["-x", "-o", "-l", "\(window.windowNumber)"], folder, name)
    }

    /// Opens a menu of the menu bar over the main window, beside the sidebar, and captures that part of the screen
    /// (a menu is a window of its own that closes when anything else is clicked, so a timer captures it while open).
    @MainActor static func captureMenu(_ title: String, _ folder: URL, _ name: String) {
        guard let window = mainWindow, let view = window.contentView,
              let menu = NSApp.mainMenu?.items.first(where: { $0.title == title })?.submenu,
              let top = NSScreen.screens.first?.frame.maxY else { return }
        let point = NSPoint(x: 300, y: view.isFlipped ? 40 : view.bounds.height - 40)
        let origin = window.convertPoint(toScreen: view.convert(point, to: nil))
        // screencapture -R counts from the top left of the main screen.
        let area = "\(Int(origin.x) - 20),\(Int(top - origin.y) - 20),480,\(Int(min(window.frame.height - 60, 460)))"
        let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
            MainActor.assumeIsolated {
                screencapture(["-x", "-R", area], folder, name)
                NSApp.mainMenu?.items.first { $0.title == title }?.submenu?.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    /// A sheet is a window of its own.
    @MainActor static func captureSheet(_ folder: URL, _ name: String) {
        guard let sheet = mainWindow?.attachedSheet else { return }
        screencapture(["-x", "-o", "-l", "\(sheet.windowNumber)"], folder, name)
    }

    @MainActor static func screencapture(_ arguments: [String], _ folder: URL, _ name: String) {
        let url = folder.appendingPathComponent(name + ".png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments + [url.path]
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 || !FileManager.default.fileExists(atPath: url.path) {
            FileHandle.standardError.write(Data("Couldn't capture \(name): screencapture needs Screen Recording permission.\n".utf8))
        }
    }
}
