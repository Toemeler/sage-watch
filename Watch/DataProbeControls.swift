import SwiftUI

/// The whole watch app: the probe's switch, what it records, what is missing, and the queue to the iPhone.
struct DataProbeControls: View {
    @ObservedObject private var probe = DataProbe.shared
    @ObservedObject private var outbox = Outbox.shared

    var body: some View {
        List {
            Section {
                Toggle("Probe", isOn: Binding(get: { probe.running }, set: { on in
                    if on { probe.start() } else { probe.stop() }
                }))
                if let since = probe.startedAt {
                    row("Since", since.formatted(date: .omitted, time: .standard))
                }
                row("Workout session", probe.sessionRunning ? "running" : "off")
                row("Lines", probe.totalLines.formatted())
                row("Live to iPhone", "\(probe.sentSnapshots)")
            } footer: {
                Text("Records every sensor and Health type the watch has and sends it to the iPhone: files every 2 min, live values every second while the iPhone is near.")
            }

            Section("iPhone") {
                row("Files waiting", "\(outbox.pending)")
                row("Files sent", "\(outbox.sent)")
                Button("Send now") { probe.shipOpenChunks() }
            }

            Section("Capture (next start)") {
                Toggle("800 Hz / 200 Hz", isOn: $probe.highRate)
                Toggle("GPS and compass", isOn: $probe.gps)
            }

            if !probe.streamLines.isEmpty {
                Section("Streams") {
                    ForEach(probe.streamLines.keys.sorted(), id: \.self) { s in
                        row(ProbeFormat.title(of: s), (probe.streamLines[s] ?? 0).formatted())
                    }
                }
            }

            if !probe.notes.isEmpty {
                Section("Missing or failed") {
                    ForEach(probe.notes, id: \.self) { n in
                        Text(n).font(.footnote).foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Text("Build \(Self.version)").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Data lab")
    }

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.footnote)
    }
}
