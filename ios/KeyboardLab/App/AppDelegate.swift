import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if ProcessInfo.processInfo.environment["LAB_RESET_EMOJI_RECENTS"] == "1" {
            UserDefaults.standard.removeObject(
                forKey: "app.useekko.keyboard.recent-emojis"
            )
        }
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = KeyboardLabViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
