import SwiftUI

/// Long-press the face to open: recording on/off, what is being captured, and the queue to the iPhone.
struct RecorderControls: View {
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var health: HealthStore
    @ObservedObject private var outbox = Outbox.shared
    @ObservedObject private var alarm = SmartAlarm.shared
    @ObservedObject private var activity = ActivityMonitor.shared

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

            Section {
                if !alarm.status.isEmpty {
                    Text(alarm.status).font(.footnote)
                }
                if alarm.nap != nil || alarm.status.hasPrefix("Nap: waiting") {
                    Button("Cancel nap alarm", role: .destructive) { alarm.cancelNap() }
                } else {
                    Button("Nap now") { alarm.napNow() }
                        .disabled(!recorder.isRunning || alarm.ringing)
                }
                if let a = activity.context {
                    row("Doing", "\(a.kind.label) since \(a.since.formatted(date: .omitted, time: .shortened))")
                }
            } header: {
                Text("Alarm")
            } footer: {
                let s = AlarmSettings.load().clamped()
                Text("Nap: wakes you when the cycle ends, \(Int(s.napEarliest))–\(Int(s.napLatest)) min after you fall asleep. Stop with the button, a hard shake or the iPhone.")
            }

            Section("Health") {
                row("Steps", health.steps.map(FaceRenderer.grouped) ?? "–")
                row("Heart rate", health.heartRate.map { "\($0) bpm" } ?? "–")
                if let p = health.problem {
                    Text(p).font(.footnote).foregroundStyle(.red)
                }
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
                // closes the current chunks too, so everything recorded so far reaches the iPhone (do this before updating Sage)
                Button("Send now") { recorder.shipOpenChunks(); outbox.resendAll() }
            }

            Section {
                Text("Sage \(Self.version)").font(.footnote).foregroundStyle(.secondary)
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
