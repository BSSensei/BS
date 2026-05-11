// Toast.swift
import UIKit

class Toast {
    static func show(_ message: String, on view: UIView) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.frame = CGRect(x: 0, y: 0, width: 200, height: 36)
        label.center = view.center
        view.addSubview(label)
        
        UIView.animate(withDuration: 0.5, delay: 2.0, options: .curveEaseOut) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
}