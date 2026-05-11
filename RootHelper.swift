import UIKit

/// 根助手：处理需要特殊权限的系统命令。
/// 在未越狱或未安装巨魔的设备上，命令执行会静默失败（不会崩溃）。
class RootHelper {

    // MARK: - 权限检测
    static var isRoot: Bool {
        getuid() == 0
    }

    static var isTrollStore: Bool {
        // 巨魔环境可以通过检测 App 自身的权限：能否在 /var/mobile 创建一个测试文件
        let testPath = "/var/mobile/Library/Preferences/.permanentstore_test"
        let success = FileManager.default.createFile(atPath: testPath, contents: nil, attributes: nil)
        if success {
            try? FileManager.default.removeItem(atPath: testPath)
        }
        return success
    }

    /// 是否具备执行系统命令的能力
    static var hasSystemPrivileges: Bool {
        isRoot || isTrollStore
    }

    // MARK: - 命令执行

    /// 执行 shell 命令（安全封装）
    @discardableResult
    static func execute(_ command: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    // MARK: - 系统工具

    /// 刷新图标缓存
    static func rebuildIconCache() {
        guard hasSystemPrivileges else { return }
        execute("uicache -a")
    }

    /// 重启主屏幕
    static func restartSpringBoard() {
        guard hasSystemPrivileges else { return }
        execute("killall -9 SpringBoard")
    }

    /// 注销设备
    static func logout() {
        guard hasSystemPrivileges else { return }
        execute("killall -9 loginwindow")
    }

    /// 重建信任缓存
    static func rebuildTrustCaches() {
        guard hasSystemPrivileges else { return }
        // 通常 trustcaches 命令在越狱环境中可用
        execute("trustcaches rebuild")
    }

    /// 清理临时文件（沙盒内的缓存，普通权限可用）
    static func cleanTemp() {
        // 清理 App 自身的临时目录
        let tempDir = NSTemporaryDirectory()
        if let files = try? FileManager.default.contentsOfDirectory(atPath: tempDir) {
            for file in files {
                try? FileManager.default.removeItem(atPath: tempDir + "/" + file)
            }
        }
        // 也可以清理 Documents/Temp
        let docsTemp = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Temp").path
        if let files = try? FileManager.default.contentsOfDirectory(atPath: docsTemp) {
            for file in files {
                try? FileManager.default.removeItem(atPath: docsTemp + "/" + file)
            }
        }
    }

    // MARK: - 权限提示

    /// 需要权限才能执行的操作，弹出提示
    static func requirePrivileges(for action: String, in viewController: UIViewController) -> Bool {
        if hasSystemPrivileges {
            return true
        } else {
            let alert = UIAlertController(
                title: "权限不足",
                message: "\(action) 需要越狱或巨魔环境。",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "确定", style: .default))
            viewController.present(alert, animated: true)
            return false
        }
    }
}