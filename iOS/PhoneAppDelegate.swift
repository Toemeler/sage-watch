import UIKit
import HealthKit

final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Receiver.shared.activate()
        return true
    }

    /// the watch app asks for Health access (needed to run its workout session); let the iPhone show the prompt
    func applicationShouldRequestHealthAuthorization(_ application: UIApplication) {
        HKHealthStore().handleAuthorizationForExtension { _, _ in }
    }
}
