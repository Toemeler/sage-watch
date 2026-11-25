import SwiftUI

/// Long-press the face to open: recording on/off, what is being captured, and the queue to the iPhone.
struct RecorderControls: View {
    @EnvironmentObject private var recorder: Recorder
    @ObservedObject private var outbox = Outbox.shared

    var body: some View {
        List {
            Section {
                Toggle("Record", isOn: Binding(
                    get: { recorder.keepRunning },
                    set: { on in
                        recorder.keepRunning = on
                        if on { recorder.start() } else { recorder.stop() }
                    }))
                if recorder.isRunning {
                    row("Since", recorder.startedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–")
                    row("Heart", recorder.bpm.map { "\($0) bpm" } ?? "waiting…")
                    row("Heart samples", "\(recorder.heartSamples)")
                    row("Motion samples", "\(recorder.motionSamples)")
                }
                if let e = recorder.lastError {
                    Text(e).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("Keeps Sage in front and records heart rate every ~5 s, wrist motion and air pressure. Changes below apply to the next start.")
            }

            Section("Capture") {
                Picker("Raw motion", selection: $recorder.rawMotionHz) {
                    Text("Off").tag(0)
                    Text("10 Hz").tag(10)
                    Text("25 Hz").tag(25)
                    Text("50 Hz").tag(50)
                    Text("100 Hz").tag(100)
                }
                Toggle("Gyroscope", isOn: $recorder.gyroscope)
                Toggle("Save to Health", isOn: $recorder.saveWorkout)
            }

            Section("iPhone") {
                row("Waiting to send", "\(outbox.pending)")
                row("Sent", "\(outbox.sent)")
                Button("Send now") { outbox.resendAll() }
            }

            if recorder.isRunning {
                Section {
                    Button("Restart with new settings") {
                        recorder.stop()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { recorder.start() }
                    }
                }
            }
        }
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
