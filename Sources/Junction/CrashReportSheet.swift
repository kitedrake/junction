import AppKit
import JunctionCore
import SwiftUI

/// After a crash (with crash reports on in Settings): the whole report, then Send Report (release builds), Copy Report
/// or Don't Send. Nothing leaves the Mac without the click.
struct CrashReportSheet: View {
    @Environment(AppModel.self) private var model
    let offer: CrashOffer
    @State private var sending = false
    @State private var problem: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: "exclamationmark.bubble")
                .font(.title2.weight(.semibold))
            Text(explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(offer.report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 320)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Crash report")
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Don't Send") { model.finishCrashOffer() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                ForEach(Array(offer.actions.enumerated()), id: \.offset) { _, action in
                    switch action {
                    case .copy:
                        // In a build without CRASH_REPORT_URL copying is all there is, so Return does it.
                        Button(copied ? "Copied" : "Copy Report") { copy() }
                            .keyboardShortcut(offer.actions.count == 1 ? .defaultAction : nil)
                    case .send:
                        Button(sending ? "Sending…" : "Send Report") { send() }
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(sending)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 640)
    }

    private var title: String {
        let processes = Set(offer.crashes.map(\.process))
        let names = processes.sorted().map { $0 == "JunctionHelper" ? RoutingXPC.helperDisplayName : $0 }
        return "\(names.isEmpty ? "Junction" : names.joined(separator: " and ")) quit unexpectedly"
    }

    private var explanation: String {
        let what = "Below is everything in the report: Junction's diagnostic report (versions, your audio devices and apps, your setup and recent routing events) and the crash log macOS wrote. It names your devices and apps, so read it first."
        return offer.destination != nil
            ? "Sending it helps fix the crash. \(what) Nothing else is sent."
            : "This copy of Junction has no address to send reports to: copy the report into a bug report if you'd like to. \(what)"
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(offer.report, forType: .string)
        copied = true
    }

    private func send() {
        sending = true
        problem = nil
        Task { @MainActor in
            let failure = await model.sendCrashReport(offer)
            sending = false
            if let failure { problem = failure } else { model.finishCrashOffer() }
        }
    }
}
