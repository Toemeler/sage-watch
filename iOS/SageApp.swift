import SwiftUI

/// Data lab (test build): the iPhone app is only the watch probe's data.
@main
struct SageApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ProbeView()
                .preferredColorScheme(.dark)
                .tint(Theme.sage)
        }
    }
}

/// plain colours for the data screens
enum Theme {
    static let ivory = Color.primary
    static let muted = Color.secondary
    static let sage = Color.green
}
