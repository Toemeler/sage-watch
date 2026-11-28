import SwiftUI

/// Data lab (test build): the watch app is only the data probe.
@main
struct SageWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                DataProbeControls()
            }
            .onAppear {
                // a probe that was on when the app last ran carries on
                if DataProbe.shared.wantsOn { DataProbe.shared.start() }
            }
            .onChange(of: phase) { _, p in
                if p == .active { Outbox.shared.resendAll() }
            }
        }
    }
}
