import UIKit

struct Theme {
    static let bg = UIColor(red: 0.05, green: 0.05, blue: 0.1, alpha: 1.0)
    static let card = UIColor(white: 0.12, alpha: 1.0)
    static let accent = UIColor.systemBlue
    static let text = UIColor.white
    static let textSecondary = UIColor(white: 0.7, alpha: 1.0)
    static let separator = UIColor(white: 0.25, alpha: 1.0)
    static let destructive = UIColor.systemRed
    static let toolbar = UIColor(white: 0.08, alpha: 1.0)
    
    static func styleNavBar(_ navBar: UINavigationBar) {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
        appearance.titleTextAttributes = [.foregroundColor: text]
        appearance.largeTitleTextAttributes = [.foregroundColor: text]
        navBar.standardAppearance = appearance
        navBar.scrollEdgeAppearance = appearance
        navBar.tintColor = accent
    }
}
