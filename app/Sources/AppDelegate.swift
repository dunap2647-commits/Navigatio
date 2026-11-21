import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.backgroundColor = .white
        
        let vc = UIViewController()
        let label = UILabel(frame: UIScreen.main.bounds)
        label.text = "Navigatio App"
        label.textAlignment = .center
        vc.view.addSubview(label)
        
        window?.rootViewController = vc
        window?.makeKeyAndVisible()
        
        return true
    }
}
