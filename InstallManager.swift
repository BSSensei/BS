// Sources/InstallManager.swift
import UIKit

/// 安装方式
enum InstallMethod: String, CaseIterable {
    case itunesstored = "itunesstored"
    case systemInstall = "系统安装"
    
    var description: String {
        switch self {
        case .itunesstored: return "itunesstored（巨魔商店）"
        case .systemInstall: return "系统进程直接安装"
        }
    }
    
    var icon: String {
        switch self {
        case .itunesstored: return "arrow.down.app.fill"
        case .systemInstall: return "gearshape.2.fill"
        }
    }
}

/// 安装结果
struct InstallResult {
    let success: Bool
    let message: String
    let method: InstallMethod
    let duration: TimeInterval
}

class InstallManager {
    
    // MARK: - 单例
    static let shared = InstallManager()
    private init() {}
    
    // MARK: - 偏好设置
    var defaultMethod: InstallMethod {
        get {
            if let raw = UserDefaults.standard.string(forKey: "default_install_method"),
               let method = InstallMethod(rawValue: raw) {
                return method
            }
            return .itunesstored
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "default_install_method")
        }
    }
    
    // MARK: - 公开方法
    
    /// 使用默认方式安装 IPA
    func install(ipaPath: String, completion: @escaping (InstallResult) -> Void) {
        install(ipaPath: ipaPath, method: defaultMethod, completion: completion)
    }
    
    /// 使用指定方式安装 IPA
    func install(ipaPath: String, method: InstallMethod, completion: @escaping (InstallResult) -> Void) {
        // 检查文件是否存在
        guard FileManager.default.fileExists(atPath: ipaPath) else {
            DispatchQueue.main.async {
                completion(InstallResult(
                    success: false,
                    message: "找不到 IPA 文件：\(ipaPath)",
                    method: method,
                    duration: 0
                ))
            }
            return
        }
        
        // 检查系统权限
        guard RootHelper.hasSystemPrivileges else {
            DispatchQueue.main.async {
                completion(InstallResult(
                    success: false,
                    message: "需要巨魔商店或越狱环境才能安装",
                    method: method,
                    duration: 0
                ))
            }
            return
        }
        
        // 后台执行安装
        DispatchQueue.global(qos: .userInitiated).async {
            let startTime = Date()
            let result: InstallResult
            
            switch method {
            case .itunesstored:
                result = self.installWithItunesstored(ipaPath: ipaPath, startTime: startTime)
            case .systemInstall:
                result = self.installWithSystem(ipaPath: ipaPath, startTime: startTime)
            }
            
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
    
    // MARK: - itunesstored 安装（巨魔商店方式）
    
    private func installWithItunesstored(ipaPath: String, startTime: Date) -> InstallResult {
        let tempDir = NSTemporaryDirectory() + "install_\(UUID().uuidString)"
        let payloadDir = tempDir + "/Payload"
        
        // 用完就删
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        
        // 第一步：解压 IPA
        let unzipCmd = "unzip -o -q '\(ipaPath)' -d '\(tempDir)'"
        _ = RootHelper.execute(unzipCmd)
        
        // 找到 .app 包
        guard let appName = try? FileManager.default.contentsOfDirectory(atPath: payloadDir).first(where: { $0.hasSuffix(".app") }) else {
            return InstallResult(
                success: false,
                message: "解压 IPA 失败",
                method: .itunesstored,
                duration: Date().timeIntervalSince(startTime)
            )
        }
        
        let appPath = payloadDir + "/" + appName
        
        // 第二步：用 itunesstored 安装
        let installCmd = "itunesstored --install-app '\(appPath)'"
        let output = RootHelper.execute(installCmd)
        print("InstallManager: itunesstored 输出：\(output)")
        
        // 第三步：检查是否安装成功
        let bundleID = getBundleID(from: appPath)
        let installed = checkAppInstalled(bundleID: bundleID)
        
        if installed {
            // 刷新图标缓存
            RootHelper.execute("uicache -a")
            
            let duration = Date().timeIntervalSince(startTime)
            let message = "安装成功！\n方式：itunesstored\nBundle ID：\(bundleID ?? "未知")"
            return InstallResult(success: true, message: message, method: .itunesstored, duration: duration)
        } else {
            let duration = Date().timeIntervalSince(startTime)
            return InstallResult(
                success: false,
                message: "安装失败\n输出：\(output)",
                method: .itunesstored,
                duration: duration
            )
        }
    }
    
    // MARK: - 系统进程安装（直接复制文件）
    
    private func installWithSystem(ipaPath: String, startTime: Date) -> InstallResult {
        let tempDir = NSTemporaryDirectory() + "install_\(UUID().uuidString)"
        let payloadDir = tempDir + "/Payload"
        
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        
        // 第一步：解压
        let unzipCmd = "unzip -o -q '\(ipaPath)' -d '\(tempDir)'"
        _ = RootHelper.execute(unzipCmd)
        
        guard let appName = try? FileManager.default.contentsOfDirectory(atPath: payloadDir).first(where: { $0.hasSuffix(".app") }) else {
            return InstallResult(
                success: false,
                message: "解压 IPA 失败",
                method: .systemInstall,
                duration: Date().timeIntervalSince(startTime)
            )
        }
        
        let appPath = payloadDir + "/" + appName
        let bundleID = getBundleID(from: appPath) ?? appName.replacingOccurrences(of: ".app", with: "")
        let executableName = appName.replacingOccurrences(of: ".app", with: "")
        
        // 第二步：目标路径
        let appContainerDir = "/var/containers/Bundle/Application/\(bundleID)"
        let dataContainerDir = "/var/containers/Data/Application/\(bundleID)"
        let targetAppPath = appContainerDir + "/" + appName
        
        // 第三步：执行安装命令序列
        let commands = [
            "mkdir -p '\(appContainerDir)'",
            "mkdir -p '\(dataContainerDir)'",
            "cp -R '\(appPath)' '\(appContainerDir)/'",
            "chown -R mobile:mobile '\(appContainerDir)'",
            "chown -R mobile:mobile '\(dataContainerDir)'",
            "chmod +x '\(targetAppPath)/\(executableName)'"
        ]
        
        for cmd in commands {
            let output = RootHelper.execute(cmd)
            if !output.isEmpty {
                print("InstallManager: 执行 [\(cmd)] → \(output)")
            }
        }
        
        // 第四步：刷新图标缓存
        RootHelper.execute("uicache -a")
        
        // 第五步：等待系统注册
        Thread.sleep(forTimeInterval: 1.5)
        
        // 第六步：验证安装
        let copied = FileManager.default.fileExists(atPath: targetAppPath)
        let registered = checkAppInstalled(bundleID: bundleID)
        
        if copied || registered {
            // 重启主屏幕让图标出现
            RootHelper.execute("killall -9 SpringBoard")
            
            let duration = Date().timeIntervalSince(startTime)
            let message = "安装成功！\n方式：系统直接安装\nBundle ID：\(bundleID)\n正在重启主屏幕…"
            return InstallResult(success: true, message: message, method: .systemInstall, duration: duration)
        } else {
            let duration = Date().timeIntervalSince(startTime)
            return InstallResult(
                success: false,
                message: "安装失败，请检查权限或手动安装",
                method: .systemInstall,
                duration: duration
            )
        }
    }
    
    // MARK: - 辅助函数
    
    /// 从 .app 中读取 Bundle ID
    private func getBundleID(from appPath: String) -> String? {
        let plistPath = appPath + "/Info.plist"
        guard let info = NSDictionary(contentsOfFile: plistPath) else { return nil }
        return info["CFBundleIdentifier"] as? String
    }
    
    /// 检查应用是否已安装
    private func checkAppInstalled(bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        
        // 方法1：通过 lsregister 检查
        let queryCmd = "lsregister -dump 2>/dev/null | grep -c '\(id)'"
        let output = RootHelper.execute(queryCmd)
        let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        
        if count > 0 { return true }
        
        // 方法2：检查应用目录是否存在
        let appPath = "/var/containers/Bundle/Application/\(id)"
        if FileManager.default.fileExists(atPath: appPath) { return true }
        
        // 方法3：遍历查找（慢但可靠）
        let findCmd = "find /var/containers/Bundle/Application -maxdepth 2 -name '*.app' -exec grep -l '\(id)' {}/Info.plist \\; 2>/dev/null | head -1"
        let result = RootHelper.execute(findCmd)
        return !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
