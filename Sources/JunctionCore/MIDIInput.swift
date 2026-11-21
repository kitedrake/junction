import CoreMIDI
import Foundation

/// Listens to every MIDI source on the Mac (controllers as they are plugged in and out, network and virtual sources
/// too) and hands their messages, with the source's name, to `onMessages` on `queue`. Made by the process that routes.
public final class MIDIInput: @unchecked Sendable {
    public typealias MessageHandler = @Sendable ([MIDIMessage], String?) -> Void
    public typealias SourcesHandler = @Sendable ([String]) -> Void

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private let queue: DispatchQueue
    private let onMessages: MessageHandler
    private let onSources: SourcesHandler
    private let lock = NSLock()
    /// The connected sources and their names; a connection's refCon is its index + 1 here. Under `lock`.
    private var sources: [(endpoint: MIDIEndpointRef, name: String)] = []

    /// Nil when CoreMIDI won't make a client (the MIDI server isn't running).
    public init?(name: String, queue: DispatchQueue, onMessages: @escaping MessageHandler,
                 onSources: @escaping SourcesHandler) {
        self.queue = queue
        self.onMessages = onMessages
        self.onSources = onSources
        let status = MIDIClientCreateWithBlock(name as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            self?.connectSources()
        }
        guard status == noErr else { return nil }
        let portStatus = MIDIInputPortCreateWithProtocol(client, "\(name) Input" as CFString, ._1_0, &port) { [weak self] list, refCon in
            self?.receive(list, refCon)
        }
        guard portStatus == noErr else { return nil }  // deinit disposes of the client
        connectSources()
    }

    deinit {
        MIDIPortDispose(port)
        MIDIClientDispose(client)
    }

    /// The names of the sources listened to.
    public var sourceNames: [String] { lock.withLock { sources.map(\.name) } }

    /// Connects to every source there is now (after a controller was plugged in or out).
    private func connectSources() {
        let old = lock.withLock { sources }
        for source in old { MIDIPortDisconnectSource(port, source.endpoint) }
        var fresh: [(MIDIEndpointRef, String)] = []
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { continue }
            var name: Unmanaged<CFString>?
            let named = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr
            fresh.append((endpoint, named ? (name?.takeRetainedValue() as String? ?? "MIDI") : "MIDI"))
        }
        lock.withLock { sources = fresh }
        for (index, source) in fresh.enumerated() {
            MIDIPortConnectSource(port, source.0, UnsafeMutableRawPointer(bitPattern: index + 1))
        }
        let names = fresh.map(\.1)
        queue.async { self.onSources(names) }
    }

    /// On CoreMIDI's thread: reads MIDI 1.0 channel messages out of the Universal MIDI Packets.
    private func receive(_ list: UnsafePointer<MIDIEventList>, _ refCon: UnsafeMutableRawPointer?) {
        var messages: [MIDIMessage] = []
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var index = 0
                while index < min(count, words.count) {
                    let word = words[index]
                    if let message = MIDIMessage.parse(umpWord: word) { messages.append(message) }
                    index += MIDIMessage.umpWordCount(word)
                }
            }
        }
        guard !messages.isEmpty else { return }
        let index = Int(bitPattern: refCon) - 1
        let name = lock.withLock { sources.indices.contains(index) ? sources[index].name : nil }
        queue.async { self.onMessages(messages, name) }
    }
}
