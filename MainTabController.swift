import UIKit

class MainTabController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // 巨魔风格 TabBar 外观
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(white: 0.08, alpha: 1)
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = .systemBlue
        tabBar.unselectedItemTintColor = .gray
        
        // 文件管理
        let fileVC = UINavigationController(rootViewController: FileViewController())
        fileVC.tabBarItem = UITabBarItem(title: "Files", image: UIImage(systemName: "folder.fill"), tag: 0)
        
        // 签名
        let signVC = UINavigationController(rootViewController: SignViewController())
        signVC.tabBarItem = UITabBarItem(title: "Sign", image: UIImage(systemName: "signature"), tag: 1)
        
        // 证书
        let certVC = UINavigationController(rootViewController: CertViewController())
        certVC.tabBarItem = UITabBarItem(title: "Certs", image: UIImage(systemName: "key.fill"), tag: 2)
        
        // 历史
        let historyVC = UINavigationController(rootViewController: HistoryViewController())
        historyVC.tabBarItem = UITabBarItem(title: "History", image: UIImage(systemName: "clock.fill"), tag: 3)
        
        // 设置
        let settingsVC = UINavigationController(rootViewController: SettingsViewController())
        settingsVC.tabBarItem = UITabBarItem(title: "Settings", image: UIImage(systemName: "gearshape.fill"), tag: 4)
        
        viewControllers = [fileVC, signVC, certVC, historyVC, settingsVC]
    }
}