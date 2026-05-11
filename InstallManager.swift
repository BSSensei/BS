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
                result = self.itunesstored安装(ipaPath: ipaPath, startTime: startTime)
            case .systemInstall:
                result = self.系统安装(ipaPath: ipaPath, startTime: startTime)
            }
            
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
    
    // MARK: - itunesstored 安装（巨魔商店方式）
    
    private func itunesstored安装(ipaPath: String, startTime: Date) -> InstallResult {
        let 临时目录 = NSTemporaryDirectory() + "安装_\(UUID().uuidString)"
        let payload目录 = 临时目录 + "/Payload"
        
        // 用完就删
        defer { try? FileManager.default.removeItem(atPath: 临时目录) }
        
        // 第一步：解压 IPA
        let 解压命令 = "unzip -o -q '\(ipaPath)' -d '\(临时目录)'"
        _ = RootHelper.execute(解压命令)
        
        // 找到 .app 包
        guard let app名称 = try? FileManager.default.contentsOfDirectory(atPath: payload目录).first(where: { $0.hasSuffix(".app") }) else {
            return InstallResult(
                success: false,
                message: "解压 IPA 失败",
                method: .itunesstored,
                duration: Date().timeIntervalSince(startTime)
            )
        }
        
        let app路径 = payload目录 + "/" + app名称
        
        // 第二步：用 itunesstored 安装
        let 安装命令 = "itunesstored --install-app '\(app路径)'"
        let 输出 = RootHelper.execute(安装命令)
        print("PermanentStore: itunesstored 输出：\(输出)")
        
        // 第三步：检查是否安装成功
        let bundleID = 获取BundleID(from: app路径)
        let 安装成功 = 检查应用已安装(bundleID: bundleID)
        
        if 安装成功 {
            // 刷新图标缓存
            RootHelper.execute("uicache -a")
            
            let 耗时 = Date().timeIntervalSince(startTime)
            let 消息 = "安装成功！\n方式：itunesstored\nBundle ID：\(bundleID ?? "未知")"
            return InstallResult(success: true, message: 消息, method: .itunesstored, duration: 耗时)
        } else {
            let 耗时 = Date().timeIntervalSince(startTime)
            return InstallResult(
                success: false,
                message: "安装失败\n输出：\(输出)",
                method: .itunesstored,
                duration: 耗时
            )
        }
    }
    
    // MARK: - 系统进程安装（直接复制文件）
    
    private func 系统安装(ipaPath: String, startTime: Date) -> InstallResult {
        let 临时目录 = NSTemporaryDirectory() + "安装_\(UUID().uuidString)"
        let payload目录 = 临时目录 + "/Payload"
        
        defer { try? FileManager.default.removeItem(atPath: 临时目录) }
        
        // 第一步：解压
        let 解压命令 = "unzip -o -q '\(ipaPath)' -d '\(临时目录)'"
        _ = RootHelper.execute(解压命令)
        
        guard let app名称 = try? FileManager.default.contentsOfDirectory(atPath: payload目录).first(where: { $0.hasSuffix(".app") }) else {
            return InstallResult(
                success: false,
                message: "解压 IPA 失败",
                method: .systemInstall,
                duration: Date().timeIntervalSince(startTime)
            )
        }
        
        let app路径 = payload目录 + "/" + app名称
        let bundleID = 获取BundleID(from: app路径) ?? app名称.replacingOccurrences(of: ".app", with: "")
        let 可执行文件名 = app名称.replacingOccurrences(of: ".app", with: "")
        
        // 第二步：目标路径
        let 应用目录 = "/var/containers/Bundle/Application/\(bundleID)"
        let 数据目录 = "/var/containers/Data/Application/\(bundleID)"
        let 目标App路径 = 应用目录 + "/" + app名称
        
        // 第三步：执行安装命令序列
        let 命令列表 = [
            "mkdir -p '\(应用目录)'",
            "mkdir -p '\(数据目录)'",
            "cp -R '\(app路径)' '\(应用目录)/'",
            "chown -R mobile:mobile '\(应用目录)'",
            "chown -R mobile:mobile '\(数据目录)'",
            "chmod +x '\(目标App路径)/\(可执行文件名)'"
        ]
        
        for 命令 in 命令列表 {
            let 输出 = RootHelper.execute(命令)
            if !输出.isEmpty {
                print("PermanentStore: 执行 [\(命令)] → \(输出)")
            }
        }
        
        // 第四步：刷新图标缓存
        RootHelper.execute("uicache -a")
        
        // 第五步：等待系统注册
        Thread.sleep(forTimeInterval: 1.5)
        
        // 第六步：验证安装
        let 已复制 = FileManager.default.fileExists(atPath: 目标App路径)
        let 已注册 = 检查应用已安装(bundleID: bundleID)
        
        if 已复制 || 已注册 {
            // 重启主屏幕让图标出现
            RootHelper.execute("killall -9 SpringBoard")
            
            let 耗时 = Date().timeIntervalSince(startTime)
            let 消息 = "安装成功！\n方式：系统直接安装\nBundle ID：\(bundleID)\n正在重启主屏幕…"
            return InstallResult(success: true, message: 消息, method: .systemInstall, duration: 耗时)
        } else {
            let 耗时 = Date().timeIntervalSince(startTime)
            return InstallResult(
                success: false,
                message: "安装失败，请检查权限或手动安装",
                method: .systemInstall,
                duration: 耗时
            )
        }
    }
    
    // MARK: - 辅助函数
    
    /// 从 .app 中读取 Bundle ID
    private func 获取BundleID(from appPath: String) -> String? {
        let plist路径 = appPath + "/Info.plist"
        guard let info = NSDictionary(contentsOfFile: plist路径) else { return nil }
        return info["CFBundleIdentifier"] as? String
    }
    
    /// 检查应用是否已安装
    private func 检查应用已安装(bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        
        // 方法1：通过 lsregister 检查
        let 查询命令 = "lsregister -dump 2>/dev/null | grep -c '\(id)'"
        let 输出 = RootHelper.execute(查询命令)
        let 计数 = Int(输出.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        
        if 计数 > 0 { return true }
        
        // 方法2：检查应用目录是否存在
        let 应用路径 = "/var/containers/Bundle/Application/\(id)"
        if FileManager.default.fileExists(atPath: 应用路径) { return true }
        
        // 方法3：遍历查找（慢但可靠）
        let 查找命令 = "find /var/containers/Bundle/Application -maxdepth 2 -name '*.app' -exec grep -l '\(id)' {}/Info.plist \\; 2>/dev/null | head -1"
        let 结果 = RootHelper.execute(查找命令)
        return !结果.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}