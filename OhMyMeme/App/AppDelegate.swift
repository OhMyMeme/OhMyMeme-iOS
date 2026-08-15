import UIKit
import SDWebImage
import SDWebImageWebPCoder

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        SDImageCodersManager.shared.addCoder(SDImageAWebPCoder.shared)

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = MainViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        AppContext.shared.queue.async {
            let ok = MemeImporter.importFile(at: url, originalName: url.lastPathComponent)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .dataChanged, object: nil)
                _ = ok
            }
        }
        return true
    }
}