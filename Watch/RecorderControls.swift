import SwiftUI

/// Long-press the face to open: recording on/off, what is being captured, and the queue to the iPhone.
struct RecorderControls: View {
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var health: HealthStore
    @ObservedObject private var outbox = Outbox.shared
    @ObservedObject private var alarm = SmartAlarm.shared
    @ObservedObject private var activity = ActivityMonitor.shared
    @ObservedObject private var audio = AudioModel.shared
    @ObservedObject private var automation = LampAutomation.shared
    @ObservedObject private var lamp = LampModel.shared

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
                if alarm.napArmed && alarm.nap == nil {
                    row("This nap", "up to \(Int(alarm.napLength)) min")     // F17: set on the face with the crown
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

            // the lamp's state at a glance here; the six automations on their own page, each explained where it is
            // switched (a footer of six paragraphs under six toggles was not read)
            Section {
                if !automation.activity.isEmpty { row("Now", automation.activity) }
                if let c = lamp.contacts.first {
                    row("Last contact", "\(c.at.formatted(date: .omitted, time: .shortened)) \(c.ok ? "ok" : "failed")\(c.background ? " · background" : "")")
                }
                NavigationLink {
                    LampAutomations()
                } label: {
                    row("Automations", "\(automation.enabledCount) of \(LampAutomation.automationCount) on")
                }
                Button(automation.previewing ? "Trying the sunrise…" : "Try sunrise (60 s)") { automation.trySunrise() }
                    .disabled(automation.previewing || !lamp.home)
                NavigationLink("Contact log") { LampContactLog() }
            } header: {
                Text("Lamp")
            } footer: {
                Text(lamp.home ? "Changing the lamp yourself always wins over the automations."
                               : "Try sunrise needs the lamp: open Sage on the iPhone at home.")
            }

            Section("Music") {
                row("iPhone", audio.status)
                Button("Check again") { audio.refresh(force: true) }
            }

            Section {
                Toggle("Track position", isOn: $recorder.trackPosition)
                if recorder.trackPosition, let fix = PositionTracker.shared.lastFix {
                    row("GPS", "±\(Int(fix.horizontalAccuracy.rounded())) m · \(fix.timestamp.formatted(date: .omitted, time: .shortened))")
                }
                if recorder.trackPosition && PositionTracker.shared.saver { row("Battery", "below 20 %: GPS saves power") }
            } header: {
                Text("Position")
            } footer: {
                Text("GPS when available, compass and steps indoors, barometer for stairs and floors. Uses a lot of battery; works while Record is on.")
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

/// Every lamp message of the last while: when, whether it arrived, and whether Sage was in the background then.
/// The lamp automations, each with one line saying what it does, under its switch.
struct LampAutomations: View {
    @ObservedObject private var automation = LampAutomation.shared

    var body: some View {
        List {
            item("Sunrise wake", $automation.sunriseOn, "Fades up while the wake window is open; full light when the alarm rings.")
            item("Wind-down", $automation.windDownOn, "In the hour before your usual bedtime a lamp that is on dims and warms; 90 min after a short night.")
                .onChange(of: automation.windDownOn) { _, _ in automation.scheduleWindDown() }
            item("Off when asleep", $automation.offWhenAsleepOn, "Fades off once the watch sees you sleeping.")
            item("Bedtime tap", $automation.bedtimeTapOn, "One quiet tap if the lamp is still bright at bedtime.")
                .onChange(of: automation.bedtimeTapOn) { _, _ in automation.rescheduleWindDown() }
            item("Arrival light", $automation.arrivalOn, "On in your evening light when you come home after dark and it is off.")
            item("Light by time of day", $automation.switchOnMemoryOn, "Switching on brings back your last evening or daytime light.")
            item("Night cap", $automation.nightCapOn, "Between bedtime and wake the slider and crown stop at 30 %; push again to go higher.")
            Text("Your own change always wins: any of these steps aside when you set the lamp. Night steps go through the iPhone while Sage runs in the background; the contact log shows whether they arrived.")
                .font(.footnote).foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        }
        .navigationTitle("Automations")
    }

    private func item(_ title: String, _ on: Binding<Bool>, _ what: String) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(what).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct LampContactLog: View {
    @ObservedObject private var lamp = LampModel.shared

    var body: some View {
        List(lamp.contacts) { c in
            HStack {
                Image(systemName: c.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(c.ok ? FaceGeometry.Palette.sage : Color(hex: 0xD9503F))
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.what).font(.system(size: 14))
                    Text("\(c.at.formatted(date: .omitted, time: .standard))\(c.background ? " · background" : "")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Contact log")
    }
}
