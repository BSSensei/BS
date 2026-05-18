//
//  EnvironmentDetector.swift
//  PermanentStore
//
//  Created for iOS 12.0+
//  Supports: TrollStore / Jailbroken / Normal (Non-jailbroken)
//

import Foundation
import UIKit

/// 运行环境类型
enum EnvironmentType: String, CaseIterable {
    case trollStore = "TrollStore"
    case jailbroken = "Jailbroken"
    case normal = "Normal"
    
    /// 是否支持系统级操作（安装/修改系统文件）
    var supportsSystemOperations: Bool {
        switch self {
        case .trollStore, .jailbroken: return true
        case .normal: return false
        }
    }
    
    /// 是否支持应用安装
    var supportsAppInstallation: Bool {
        switch self {
        case .trollStore: return true
        case .jailbroken, .normal: return false // 越狱环境需额外工具，普通环境不支持
        }
    }
}

/// 环境检测器（单例）
final class EnvironmentDetector {
    
    // MARK: - Singleton
    static let shared = EnvironmentDetector()
    private init() {}
    
    // MARK: - Current Environment
    lazy var current: EnvironmentType = detectEnvironment()
    
    // MARK: - Detection Logic
    private func detectEnvironment() -> EnvironmentType {
        // 1. 优先检测 TrollStore（最宽松且最可靠）
        if hasTrollStore() {
            return .trollStore
        }
        
        // 2. 检测越狱（root 权限）
        if hasRootPrivileges() {
            return .jailbroken
        }
        
        // 3. 默认：无特殊权限环境
        return .normal
    }
    
    // MARK: - TrollStore Detection
    /// 检测是否安装 TrollStore
    private func hasTrollStore() -> Bool {
        let trollPaths = [
            "/var/containers/Bundle/Application/TrollStore/TrollStore.app",
            "/Applications/TrollStore.app"
        ]
        
        for path in trollPaths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }
        return false
    }
    
    // MARK: - Jailbreak Detection
    /// 检测是否拥有 root 权限（越狱标志）
    private func hasRootPrivileges() -> Bool {
        getuid() == 0
    }
    
    // MARK: - Feature Availability Helpers
    /// 是否可安装应用（仅 TrollStore 支持）
    var canInstallApps: Bool {
        current.supportsAppInstallation
    }
    
    /// 是否可使用系统工具（如重建缓存、重启 SpringBoard）
    var canUseSystemTools: Bool {
        current.supportsSystemOperations
    }
    
    /// 是否可修改系统文件
    var canModifySystemFiles: Bool {
        current.supportsSystemOperations
    }
}

// MARK: - UI Adaptation Extension
extension EnvironmentDetector {
    /// 根据环境自动配置 UI 组件
    func configureUI(
        installButton: UIButton?,
        systemToolsSection: UIView?,
        signButton: UIButton?
    ) {
        installButton?.isEnabled = canInstallApps
        systemToolsSection?.isHidden = !canUseSystemTools
        signButton?.isEnabled = true // 签名功能在所有环境可用
    }
}
