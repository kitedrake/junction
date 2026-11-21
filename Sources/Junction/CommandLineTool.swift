import CoreAudio
import Foundation
import JunctionCore
import JunctionKernel

/// `Junction --list | --diagnose [file] | --self-test [folder] | --loopback-test | --device-test | --help`
enum CommandLineTool {
    static func run(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "--list": return list()
        case "--diagnose": return diagnose(to: arguments.dropFirst().first)
        case "--self-test": return selfTest(folder: arguments.dropFirst().first)
        case "--loopback-test": return loopbackTest()
        case "--device-test": return deviceTest()
        default:
            print("""
            Junction: virtual audio devices and an audio router.
              --list            Driver status, audio devices, default devices and apps using audio.
              --diagnose [file] A report for bug reports: versions, devices, apps, the routing plan, recent routing
                                events and the saved setup (it names your devices and apps). No audio is opened.
              --self-test [dir] Checks the bundled driver and routing helper, the planner, the mixing kernel, the
                                helper's XPC messages and saving (no audio; nothing is registered or launched).
              --loopback-test   With the driver installed: plays a tone into a temporary virtual device and checks
                                it comes back out. Needs microphone permission for the calling app (e.g. Terminal).
              --device-test     With the driver installed: adds a temporary virtual device, renames it, changes its
                                channels and sample rate, turns it off and on, and checks Core Audio follows each step.
            """)
            return 0
        }
    }

    // MARK: --diagnose

    static func diagnose(to path: String?) -> Int32 {
        let store = Store()
        var graph = store.load() ?? Graph()
        graph.upgrade()
        let inventory = HAL.readInventory()
        let report = Diagnostics.report(
            graph: graph, inventory: inventory, plan: Planner.plan(graph, inventory: inventory), statuses: nil,
            events: EventLog.savedLines(at: store.folder.appendingPathComponent("events.log"), count: 200),
            appVersion: AppModel.appVersion, bundledDriver: DriverClient.bundledVersion)
        guard let path else {
            print(report, terminator: "")
            return 0
        }
        do {
            try Data(report.utf8).write(to: URL(fileURLWithPath: path))
            print("Wrote \(path)")
            return 0
        } catch {
            print("Couldn't write \(path): \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: --list

    static func list() -> Int32 {
        let inventory = HAL.readInventory()
        switch inventory.driver {
        case .notInstalled: print("Driver: not installed (\(DriverClient.installPath))")
        case .installed(let version): print("Driver: installed, version \(version)")
        }
        switch DriverUpdate(installed: inventory.driver, bundled: DriverClient.bundledVersion) {
        case .available(_, let bundled): print("Driver update available: this app has \(bundled)")
        case .appIsOlder(_, let bundled): print("This app is older: its driver is \(bundled)")
        case .notInstalled, .upToDate: break
        }
        if let published = DriverClient.publishedConfiguration() {
            print("Published virtual devices: \(published.count)")
            for entry in published {
                print("  \(entry["name"] ?? "?")  \(entry["channels"] ?? "?") ch  \(entry["sampleRate"] ?? "?") Hz  \(entry["uid"] ?? "?")")
            }
        }
        print("Devices:")
        for device in inventory.devices {
            var marks: [String] = []
            if device.uid == inventory.defaultOutputUID { marks.append("default output") }
            if device.uid == inventory.defaultInputUID { marks.append("default input") }
            if device.isJunction { marks.append("Junction") }
            let suffix = marks.isEmpty ? "" : "  [\(marks.joined(separator: ", "))]"
            print("  \(device.name): in \(device.inputChannels), out \(device.outputChannels), \(Int(device.sampleRate)) Hz  \(device.uid)\(suffix)")
        }
        print("Apps using audio:")
        for app in inventory.apps {
            print("  \(app.name)\(app.isPlaying ? " (playing)" : "")  \(app.bundleID)")
        }
        return 0
    }

    // MARK: --self-test

    static func selfTest(folder: String?) -> Int32 {
        final class Tally { var failures = 0 }
        let tally = Tally()
        func check(_ condition: Bool, _ message: String) {
            print((condition ? "ok   " : "FAIL ") + message)
            if !condition { tally.failures += 1 }
        }

        // The driver shipped in the app: present, signed, and its factory loads.
        if let url = DriverClient.bundledDriverURL, let bundle = CFBundleCreate(nil, url as CFURL) {
            let info = Bundle(url: url)?.infoDictionary ?? [:]
            let factories = info["CFPlugInFactories"] as? [String: String] ?? [:]
            let types = info["CFPlugInTypes"] as? [String: [String]] ?? [:]
            check(factories.values.contains("JunctionDriver_Create"), "driver names its factory")
            check(types["443ABAB8-E7B3-491A-B985-BEB9187030DB"]?.contains(where: { factories[$0] != nil }) ?? false,
                  "driver registers as an AudioServerPlugIn")
            check(signatureIsValid(url), "driver is code-signed")
            let icons = DeviceIcon.allCases.filter {
                !FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Resources/\($0.rawValue).icns").path)
            }
            check(icons.isEmpty, "driver carries its device icons" + (icons.isEmpty ? "" : " (missing: \(icons.map(\.rawValue)))"))
            var loaded = false
            if CFBundleLoadExecutable(bundle), let symbol = CFBundleGetFunctionPointerForName(bundle, "JunctionDriver_Create" as CFString) {
                typealias Factory = @convention(c) (CFAllocator?, CFUUID) -> UnsafeMutableRawPointer?
                let factory = unsafeBitCast(symbol, to: Factory.self)
                let pluginType = CFUUIDGetConstantUUIDWithBytes(nil, 0x44, 0x3A, 0xBA, 0xB8, 0xE7, 0xB3, 0x49, 0x1A, 0xB9, 0x85, 0xBE,
                                                                0xB9, 0x18, 0x70, 0x30, 0xDB)!
                loaded = factory(nil, pluginType) != nil
            }
            check(loaded, "driver loads and creates its interface")
        } else {
            check(false, "driver bundled in the app (Contents/Resources/JunctionDriver.driver)")
        }
        check(Bundle.main.url(forResource: "install-driver", withExtension: "sh") != nil, "install script bundled")

        // Junction Helper: a signed UI-element app inside Junction.app, with the launch agent SMAppService registers.
        let helperURL = RoutingHelper.helperURL
        if let info = Bundle(url: helperURL)?.infoDictionary {
            check(info["CFBundleIdentifier"] as? String == RoutingXPC.helperBundleIdentifier, "helper's bundle identifier")
            check(info["LSUIElement"] as? Bool == true, "helper has no Dock icon (LSUIElement)")
            check((info["NSMicrophoneUsageDescription"] as? String)?.contains(RoutingXPC.helperDisplayName) ?? false,
                  "helper's permission prompts name it")
            check(FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent(RoutingXPC.helperExecutablePath).path),
                  "helper executable present")
            check(signatureIsValid(helperURL), "helper is code-signed")
        } else {
            check(false, "routing helper bundled in the app (\(RoutingXPC.helperBundlePath))")
        }
        if let agent = NSDictionary(contentsOf: RoutingHelper.agentPlistURL) as? [String: Any] {
            check(agent["Label"] as? String == RoutingXPC.machServiceName
                  && agent["BundleProgram"] as? String == RoutingXPC.helperExecutablePath
                  && (agent["MachServices"] as? [String: Any])?[RoutingXPC.machServiceName] != nil,
                  "launch agent names the helper and its XPC service")
        } else {
            check(false, "launch agent bundled (Contents/Library/LaunchAgents/\(RoutingXPC.agentPlistName))")
        }
        let usesHelper = Bundle.main.object(forInfoDictionaryKey: RoutingXPC.usesHelperKey) as? Bool
        check(usesHelper != nil, "this build routes \(usesHelper == true ? "in the helper" : "inside the app")")

        // Planning: "stream without chat" lays out as expected.
        var graph = Graph()
        let discord = AppRef(bundleID: "com.hnc.Discord", name: "Discord")
        let device = Templates.streamWithoutChat(&graph, excluding: [discord])
        let mic = Node(kind: .defaultInput, x: 60, y: 300, canvas: device.id)
        graph.nodes.append(mic)
        graph.cables += Rules.busCables(from: mic.id, to: graph.deviceNode(device.id)?.id ?? UUID(), graph: graph,
                                        inventory: Inventory(devices: [DeviceInfo(uid: "mic", name: "Mic", inputChannels: 1, outputChannels: 0)],
                                                             defaultInputUID: "mic"))
        let inventory = Inventory(
            devices: [DeviceInfo(uid: "mic", name: "Mic", inputChannels: 1, outputChannels: 0),
                      DeviceInfo(uid: device.uid, name: device.name, inputChannels: 2, outputChannels: 2, isJunction: true)],
            defaultInputUID: "mic", driver: .installed(version: "test"))
        let plan = Planner.plan(graph, inventory: inventory)
        let sink = plan.sinks.first
        check(plan.sinks.count == 1, "one sink planned")
        check(sink?.subDevices.map(\.uid) == [device.uid, "mic"], "sub-devices: virtual device first, then the mic")
        check(sink?.routes.map(\.input) == [3, 4, 2, 2], "routes read the tap after the devices (\(sink?.routes.map(\.input) ?? []))")
        check(sink?.taps.first?.mode == .allExcept(["com.hnc.Discord"]), "tap leaves Discord out")

        // Kernel: a known mix.
        let frames = 128
        let input = UnsafeMutablePointer<Float>.allocate(capacity: frames * 3)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer { input.deallocate(); output.deallocate() }
        for f in 0..<frames {
            input[f * 3] = 0.5; input[f * 3 + 1] = 0.25; input[f * 3 + 2] = -0.25
            output[f * 2] = 9; output[f * 2 + 1] = 9
        }
        let inList = AudioBufferList.allocate(maximumBuffers: 1)
        let outList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(inList.unsafeMutablePointer); free(outList.unsafeMutablePointer) }
        inList[0] = AudioBuffer(mNumberChannels: 3, mDataByteSize: UInt32(frames * 12), mData: input)
        outList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: output)
        if let renderer = jk_renderer_create(3, 2, 3, [0, 1, 2], [0, 0, 1], [1, 2, 1]) {
            var time = AudioTimeStamp()
            _ = jk_renderer_ioproc(0, &time, inList.unsafePointer, &time, outList.unsafeMutablePointer, &time,
                                   UnsafeMutableRawPointer(renderer))
            check(abs(output[0] - 1.0) < 1e-6 && abs(output[1] + 0.25) < 1e-6, "kernel mixes routes with gains")
            jk_renderer_destroy(renderer)
        } else {
            check(false, "kernel renderer created")
        }

        // Sample-rate conversion: a 44.1 kHz source into a 48 kHz sink stays out of the aggregate and is converted.
        var converting = inventory
        converting.devices[0].sampleRate = 44100
        let convertingPlan = Planner.plan(graph, inventory: converting)
        check(convertingPlan.sinks.first?.converted.map(\.uid) == ["mic"]
              && convertingPlan.sinks.first?.subDevices.map(\.uid) == [device.uid],
              "a 44.1 kHz mic into a 48 kHz device is converted")
        if let converter = jk_converter_create(1, 44100, 48000) {
            let block = UnsafeMutablePointer<Float>.allocate(capacity: 441), converted = UnsafeMutablePointer<Float>.allocate(capacity: 480)
            defer { block.deallocate(); converted.deallocate() }
            block.initialize(repeating: 0.5, count: 441)
            let list = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(list.unsafeMutablePointer) }
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 441 * 4, mData: block)
            for _ in 0..<20 {
                jk_converter_write(converter, list.unsafePointer, nil)
                jk_converter_read(converter, converted, 480, 480, nil)
            }
            check(abs(converted[479] - 0.5) < 1e-3 && jk_converter_underrun_count(converter) == 0, "kernel converts 44.1 to 48 kHz")
            jk_converter_destroy(converter)
        } else {
            check(false, "kernel converter created")
        }

        // Editing: duplicating the System Audio node brings its cables into the device; undo puts the graph back.
        final class Held { var graph: Graph; init(_ graph: Graph) { self.graph = graph } }
        let held = Held(graph)
        let history = EditHistory(read: { held.graph }, write: { held.graph = $0 })
        let sources = Set(graph.nodes.filter(\.kind.isTap).map(\.id))
        if let copied = Editing.copy(sources, from: graph) {
            history.perform("Duplicate") { Editing.paste(copied, into: &$0, canvas: device.id, inventory: inventory) }
        }
        check(held.graph.cables.count == graph.cables.count + 2, "duplicating a node brings its cables")
        history.undo()
        check(held.graph == graph, "undo restores the graph")

        // The helper's XPC protocol, through a listener in this process and a stand-in router.
        check(xpcRoundTrip(graph: graph, inventory: inventory), "routing service answers over XPC and routes what it is sent")

        // Saving.
        let base = folder.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let store = Store(folder: base.appendingPathComponent("junction-self-test-\(UUID().uuidString)"))
        do {
            try store.save(graph)
            check(store.load() == graph, "graph saves and loads unchanged")
        } catch {
            check(false, "graph saves (\(error.localizedDescription))")
        }
        try? FileManager.default.removeItem(at: store.folder)

        // Reading the system needs no permission.
        let live = HAL.readInventory()
        check(true, "read \(live.devices.count) audio devices; driver \(live.driver.isInstalled ? "installed" : "not installed")")

        print(tally.failures == 0 ? "Self-test passed." : "Self-test: \(tally.failures) failure(s).")
        return tally.failures == 0 ? 0 : 1
    }

    /// Says hello to a RoutingService on an anonymous listener, sends it the setup and waits for it to be planned.
    private static func xpcRoundTrip(graph: Graph, inventory: Inventory) -> Bool {
        final class StandIn: SinkRouting, @unchecked Sendable {
            let planned = DispatchSemaphore(value: 0)
            func apply(_ plan: RoutingPlan) { if !plan.sinks.isEmpty { planned.signal() } }
            func forgetAfterRestart() {}
            func stopAll() {}
            func rebuildAll() {}
            func resetHealth() {}
            func processesChanged() {}
            func takeMeters() -> [PortKey: Float] { [:] }
        }
        let standIn = StandIn()
        let environment = RoutingService.Environment(readInventory: { inventory }, permission: { .allowed },
                                                     requestMicrophone: { $0() }, processName: "Self-Test")
        let service = RoutingService(graph: Graph(), keepRouting: false, events: EventLog(file: nil),
                                     queue: DispatchQueue(label: "local.junction.self-test.service"),
                                     environment: environment) { _ in standIn }
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        defer { listener.invalidate() }
        let welcomed = DispatchSemaphore(value: 0)
        let client = RoutingClient(endpoint: listener.endpoint, keepRouting: false,
                                   callbackQueue: DispatchQueue(label: "local.junction.self-test.client")) { event in
            if case .connected = event { welcomed.signal() }
        }
        client.connect()
        guard welcomed.wait(timeout: .now() + 5) == .success else { return false }
        client.send(graph: graph)
        let routed = standIn.planned.wait(timeout: .now() + 5) == .success
        client.goodbye()
        return routed
    }

    private static func signatureIsValid(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
    }

    // MARK: --loopback-test

    /// Adds a temporary device next to the published ones, plays a 997 Hz tone into its output and listens to its
    /// input, then puts the driver's device list back.
    static func loopbackTest() -> Int32 {
        guard DriverClient.status().isInstalled, let existing = DriverClient.publishedDevices() else {
            print("The Junction driver isn't installed (or coreaudiod hasn't loaded it).")
            return 1
        }
        let test = VirtualDevice(id: UUID(uuidString: "4A554E43-5445-5354-0000-000000000001")!, name: "Junction Loopback Test")
        func restore() { try? DriverClient.publish(existing.filter { $0.uid != test.uid }) }
        do {
            try DriverClient.publish(existing.filter { $0.uid != test.uid } + [test])
        } catch {
            print("Couldn't add the test device: \(error.localizedDescription)")
            return 1
        }
        defer { restore() }
        var device: AudioObjectID?
        for _ in 0..<60 {
            device = HAL.deviceID(forUID: test.uid)
            if device != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let device else {
            print("FAIL: the test device didn't appear.")
            return 1
        }
        print("Test device appeared (object \(device)). Playing a tone for 1.5 s…")

        let rate = 48000.0
        let capacity = Int(rate * 2)
        let captured = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        captured.initialize(repeating: 0, count: capacity)
        defer { captured.deallocate() }
        nonisolated(unsafe) var written = 0
        nonisolated(unsafe) var phase = 0.0
        let queue = DispatchQueue(label: "local.junction.loopback-test")
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { _, input, _, output, _ in
            let outs = UnsafeMutableAudioBufferListPointer(output)
            for buffer in outs {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else { continue }
                let channels = Int(buffer.mNumberChannels)
                let frames = Int(buffer.mDataByteSize) / (4 * channels)
                var p = phase
                for f in 0..<frames {
                    let value = Float(0.5 * sin(p))
                    p += 2 * .pi * 997 / rate
                    for c in 0..<channels { data[f * channels + c] = value }
                }
                phase = p.truncatingRemainder(dividingBy: 2 * .pi)
            }
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            if let buffer = ins.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 {
                let channels = Int(buffer.mNumberChannels)
                let frames = Int(buffer.mDataByteSize) / (4 * channels)
                for f in 0..<frames where written < capacity {
                    captured[written] = data[f * channels]
                    written += 1
                }
            }
        }
        guard status == noErr, let procID else {
            print("FAIL: couldn't open the device (\(HAL.describe(status))).")
            return 1
        }
        status = AudioDeviceStart(device, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device, procID)
            print("FAIL: couldn't start the device (\(HAL.describe(status))).")
            return 1
        }
        Thread.sleep(forTimeInterval: 1.5)
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)

        let count = queue.sync { written }
        let tail = Array(UnsafeBufferPointer(start: captured, count: count).suffix(Int(rate / 2)))
        let rms = tail.isEmpty ? 0 : sqrt(tail.reduce(0) { $0 + Double($1 * $1) } / Double(tail.count))
        var crossings = 0
        for i in 1..<max(1, tail.count) where (tail[i - 1] < 0) != (tail[i] < 0) { crossings += 1 }
        let frequency = Double(crossings) / 2 / (Double(tail.count) / rate)
        print(String(format: "Captured %d frames; level %.3f (expected ~0.354), frequency ~%.0f Hz (expected 997).", count, rms, frequency))
        if count == 0 || rms < 0.01 {
            print("FAIL: nothing came back. If the level is 0, allow microphone access for the app running this test.")
            return 1
        }
        guard abs(rms - 0.3536) < 0.05, abs(frequency - 997) < 30 else {
            print("FAIL: the tone came back changed.")
            return 1
        }
        print("Loopback test passed.")
        return 0
    }
}
