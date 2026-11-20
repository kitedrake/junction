import AppKit
import JunctionCore
import SwiftUI

/// A made-up setup for screenshots and demos: nothing is read from or sent to Core Audio, nothing is saved.
enum Demo {
    static let discord = AppRef(bundleID: "com.hnc.Discord", name: "Discord")

    @MainActor static func load(into model: AppModel) {
        let stream = VirtualDevice(name: "Stream Mix")
        let recording = VirtualDevice(name: "Recording", channels: 4)
        let headphones = DeviceInfo(uid: "demo.headphones", name: "AirPods Pro", inputChannels: 1, outputChannels: 2)
        let system = Node(kind: .systemAudio(excluding: [discord]), x: 60, y: 50)
        let mic = Node(kind: .defaultInput, x: 60, y: 250)
        let chat = Node(kind: .application(discord), x: 60, y: 420)
        let streamNode = Node(kind: .virtualDevice(stream.id), x: 430, y: 110)
        let recordingNode = Node(kind: .virtualDevice(recording.id), x: 800, y: 250)
        let phones = Node(kind: .device(headphones.ref), x: 800, y: 40)
        func cable(_ a: Node, _ ac: Int, _ b: Node, _ bc: Int, _ dB: Double = 0) -> Cable {
            Cable(from: PortRef(node: a.id, channel: ac), to: PortRef(node: b.id, channel: bc), gainDB: dB)
        }
        var graph = Graph(virtualDevices: [stream, recording], nodes: [system, mic, chat, streamNode, recordingNode, phones])
        graph.cables = [
            cable(system, 0, streamNode, 0), cable(system, 1, streamNode, 1),
            cable(mic, 0, streamNode, 0, -3), cable(mic, 0, streamNode, 1, -3),
            cable(streamNode, 0, recordingNode, 0), cable(streamNode, 1, recordingNode, 1),
            cable(chat, 0, recordingNode, 2), cable(chat, 1, recordingNode, 3),
            cable(streamNode, 0, phones, 0, -12), cable(streamNode, 1, phones, 1, -12),
        ]
        model.graph = graph
        let inventory = Inventory(
            devices: [
                DeviceInfo(uid: "demo.speakers", name: "MacBook Pro Speakers", inputChannels: 0, outputChannels: 2),
                DeviceInfo(uid: "demo.mic", name: "MacBook Pro Microphone", inputChannels: 1, outputChannels: 0),
                DeviceInfo(uid: "demo.interface", name: "Scarlett 2i2 USB", inputChannels: 2, outputChannels: 2),
                headphones,
                DeviceInfo(uid: stream.uid, name: stream.name, inputChannels: 2, outputChannels: 2, isJunction: true),
                DeviceInfo(uid: recording.uid, name: recording.name, inputChannels: 4, outputChannels: 4, isJunction: true),
            ],
            apps: [
                AudioApp(bundleID: discord.bundleID, name: "Discord", isPlaying: true),
                AudioApp(bundleID: "com.apple.Music", name: "Music", isPlaying: true),
                AudioApp(bundleID: "com.apple.Safari", name: "Safari"),
            ],
            defaultOutputUID: "demo.speakers", defaultInputUID: "demo.mic",
            driver: .installed(version: DriverClient.bundledVersion ?? "0.1.1"))
        let running = SinkStatus(state: .running)
        var meters: [PortKey: Float] = [:]
        func meter(_ node: Node, _ output: Bool, _ values: [Float]) {
            for (channel, value) in values.enumerated() { meters[PortKey(node: node.id, isOutput: output, channel: channel)] = value }
        }
        meter(system, true, [0.42, 0.37])
        meter(mic, true, [0.18])
        meter(chat, true, [0.3, 0.3])
        meter(streamNode, false, [0.5, 0.45])
        meter(streamNode, true, [0.5, 0.45])
        meter(recordingNode, false, [0.5, 0.45, 0.3, 0.3])
        meter(phones, false, [0.12, 0.11])
        model.setDemoState(inventory: inventory, statuses: [streamNode.id: running, recordingNode.id: running, phones.id: running],
                           meters: meters)
        model.selection = .node(system.id)
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
            resize(1280, 720)
            try? await Task.sleep(for: .seconds(1))
            await both("canvas")  // System Audio selected: the apps it leaves out

            if let stream = model.graph.nodes.first(where: { if case .virtualDevice = $0.kind { true } else { false } }) {
                model.selection = .node(stream.id)
            }
            await both("device")
            if let cable = model.graph.cables.first(where: { $0.gainDB < 0 }) { model.selection = .cable(cable.id) }
            await both("cable")

            model.graph = Graph()
            model.selection = nil
            model.setDemoState(inventory: model.inventory, statuses: [:], meters: [:])
            await both("empty")

            model.showStreamTemplate = true
            try? await Task.sleep(for: .milliseconds(600))
            await both("stream-template", sheet: true)
            model.showStreamTemplate = false
            try? await Task.sleep(for: .milliseconds(500))

            model.setDemoState(inventory: Inventory(), statuses: [:], meters: [:])
            Templates.streamWithoutChat(&model.graph, excluding: [Demo.discord])
            await both("no-driver")
            resize(980, 560)
            await both("minimum-size")
            NSApp.terminate(nil)
        }
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

    /// A sheet is a window of its own.
    @MainActor static func captureSheet(_ folder: URL, _ name: String) {
        guard let sheet = mainWindow?.attachedSheet else { return }
        screencapture(["-x", "-o", "-l", "\(sheet.windowNumber)"], folder, name)
    }

    @MainActor private static func screencapture(_ arguments: [String], _ folder: URL, _ name: String) {
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
