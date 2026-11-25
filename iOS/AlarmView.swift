import SwiftUI
import WatchConnectivity

/// How the silent alarm vibrates, with a button that tests it on the watch. The settings are saved here and sent to
/// the watch, where the real smart alarm uses them too.
struct AlarmView: View {
    @State private var settings = AlarmSettings.load()
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        List {
            Section {
                Button {
                    send([AlarmLink.commandKey: AlarmLink.test, AlarmLink.settingsKey: settings.dictionary])
                } label: {
                    Label(testTitle, systemImage: "applewatch.radiowaves.left.and.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.sage)
                .foregroundStyle(.black)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .disabled(busy)

                Button(role: .destructive) {
                    send([AlarmLink.commandKey: AlarmLink.stop])
                } label: {
                    Label("Stop test", systemImage: "stop.circle")
                }

                if let status {
                    Text(status).font(.footnote).foregroundStyle(Theme.muted)
                }
            } footer: {
                Text("The test plays the whole climb from the first to the last strength in its first 60 %, then stays at full strength. Stop it here or on the watch.")
            }

            Section {
                levelRow("First pulses", value: $settings.startLevel)
                levelRow("Full strength", value: $settings.peakLevel)
                sliderRow("Climb to full strength", value: $settings.rampMinutes, range: AlarmSettings.rampRange, step: 0.5,
                          text: settings.rampMinutes == 0 ? "at once" : minutes(settings.rampMinutes))
            } header: {
                Text("Strength")
            } footer: {
                Text("Click is the faintest, Buzz the strongest. Tap the play button to feel one on the watch. The real alarm climbs over the time set here.")
            }

            Section("Rhythm") {
                sliderRow("Pause between pulses", value: $settings.gap, range: AlarmSettings.gapRange, step: 0.5,
                          text: seconds(settings.effectiveGap))
                sliderRow("Taps per pulse", value: Binding(get: { Double(settings.taps) }, set: { settings.taps = Int($0.rounded()) }),
                          range: Double(AlarmSettings.tapsRange.lowerBound)...Double(AlarmSettings.tapsRange.upperBound), step: 1,
                          text: "\(settings.taps)")
            }

            Section {
                sliderRow("Test length", value: $settings.testSeconds, range: AlarmSettings.testRange, step: 5,
                          text: seconds(settings.testSeconds))
                sliderRow("Test starts", value: $settings.testDelayMinutes, range: AlarmSettings.delayRange, step: 1,
                          text: settings.testDelayMinutes == 0 ? "now" : "in \(minutes(settings.testDelayMinutes))")
            } header: {
                Text("Test")
            } footer: {
                Text("To check that it wakes you, set a start a few minutes away and lie down. A delayed test needs Record on (the watch keeps Sage running only while it records).")
            }

            Section {
                Button("Reset to default") { settings = AlarmSettings() }
            } footer: {
                Text("Saved on the watch too: the smart alarm (18:15–18:30 and 06:00–06:30) vibrates the same way. Silent mode mutes any tick sound but not the taps.")
            }
        }
        .navigationTitle("Vibration alarm")
        .onChange(of: settings) { _, new in
            var s = new
            if s.peakLevel < s.startLevel {
                s.peakLevel = s.startLevel          // keep the climb going up
                settings = s
                return
            }
            s.save()
            sync(s)
        }
    }

    private var testTitle: String {
        if busy { return "Sending…" }
        return settings.testDelayMinutes == 0 ? "Test vibration on the watch" : "Test in \(minutes(settings.testDelayMinutes))"
    }

    // MARK: rows

    private func levelRow(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(AlarmLevel.name(value.wrappedValue)).foregroundStyle(Theme.muted).monospacedDigit()
                Button {
                    send([AlarmLink.commandKey: AlarmLink.preview, AlarmLink.levelKey: value.wrappedValue])
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Feel \(AlarmLevel.name(value.wrappedValue)) on the watch")
            }
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(AlarmSettings.levels.lowerBound)...Double(AlarmSettings.levels.upperBound), step: 1)
                .tint(Theme.sage)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(text).foregroundStyle(Theme.muted).monospacedDigit()
            }
            Slider(value: value, in: range, step: step).tint(Theme.sage)
        }
    }

    private func minutes(_ m: Double) -> String {
        m == m.rounded() ? "\(Int(m)) min" : String(format: "%.1f min", m)
    }

    private func seconds(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s)) s" : String(format: "%.1f s", s)
    }

    // MARK: watch link

    /// the latest settings reach the watch even while Sage isn't running there
    private func sync(_ s: AlarmSettings) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext([AlarmLink.settingsKey: s.dictionary])
    }

    private func send(_ message: [String: Any]) {
        guard WCSession.isSupported() else { status = "This iPhone has no paired watch."; return }
        let session = WCSession.default
        guard session.activationState == .activated else { status = "Still connecting to the watch. Try again in a moment."; return }
        guard session.isReachable else {
            status = "The watch isn't reachable. Raise your wrist so Sage is on screen (with Record on it stays reachable), then try again."
            return
        }
        busy = true
        session.sendMessage(message, replyHandler: { reply in
            DispatchQueue.main.async {
                busy = false
                status = reply[AlarmLink.textKey] as? String ?? "Sent."
            }
        }, errorHandler: { error in
            DispatchQueue.main.async {
                busy = false
                status = "Couldn't reach the watch: \(error.localizedDescription)"
            }
        })
    }
}
