// Sources/SigningService.swift
import Foundation

class SigningService {

    // MARK: - 签名配置
    struct SignConfig {
        enum Engine: String, CaseIterable { case ldid2, zsign }
        enum Mode: String, CaseIterable { case adhoc, real }

        var engine: Engine = .ldid2
        var mode: Mode = .adhoc

        // ---- 文件路径 ----
        var ipaPath: String?

        // ---- 证书相关 ----
        var certPath: String?
        var keyPath: String?
        var certPassword: String = "troll"
        var provPath: String?

        // ---- Entitlements ----
        var entitlementContent: String?

        // ---- Ad-hoc 增强选项 ----
        var teamID: String = ""
        var platformApp: Bool = false

        // ---- 应用修改 ----
        var bundleId: String?
        var displayName: String?
        var removeDeviceLimits: Bool = false
    }

    // MARK: - 签名单个 App Bundle
    static func signAppBundle(at appPath: String, config: SignConfig) -> Bool {
        let binaryName = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        let binaryPath = appPath + "/" + binaryName

        // 1. 修改 Info.plist
        modifyInfoPlist(at: appPath, config: config)

        // 2. 准备 entitlements 临时 plist 文件
        var entPath: String? = nil
        if let entContent = buildEntitlementsContent(config: config) {
            let tempEnt = NSTemporaryDirectory() + "ent_\(UUID().uuidString).plist"
            do {
                try entContent.write(toFile: tempEnt, atomically: true, encoding: .utf8)
                entPath = tempEnt
            } catch {
                print("PermanentStore: 写入 entitlements 失败: \(error)")
                return false
            }
        }

        // 3. 使用 RootHelper 执行命令
        return runSignCommand(binaryPath: binaryPath, config: config, entPath: entPath)
    }

    // MARK: - 底层签名命令（使用 RootHelper）
    private static func runSignCommand(binaryPath: String, config: SignConfig, entPath: String?) -> Bool {
        var cmd = ""

        switch config.engine {
        case .ldid2:
            cmd = "ldid2"
            if let ent = entPath { cmd += " -S\(ent)" }
            if config.mode == .adhoc {
                if !config.teamID.isEmpty { cmd += " -K\(config.teamID)" }
            } else {
                guard let cert = config.certPath else { return false }
                cmd += " -C\(cert) -p\(config.certPassword)"
            }
            cmd += " \(binaryPath)"

        case .zsign:
            cmd = "zsign"
            if let ent = entPath { cmd += " -e \(ent)" }
            if config.mode == .adhoc {
                cmd += " -a"
            } else {
                guard let cert = config.certPath else { return false }
                cmd += " -k \(cert) -p \(config.certPassword)"
                if let prov = config.provPath, !prov.isEmpty { cmd += " -m \(prov)" }
            }
            cmd += " \(binaryPath)"
        }

        let output = RootHelper.execute(cmd)
        print("PermanentStore: 签名命令输出: \(output)")
        return !output.contains("error") && !output.contains("Error")
    }

    // MARK: - 完整 IPA 签名流程
    static func signIPA(config: SignConfig) -> String? {
        guard let ipaPath = config.ipaPath else { return nil }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sign_\(UUID().uuidString)")
        let payloadDir = tempDir.appendingPathComponent("Payload")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. 解压 IPA
        guard unzip(ipaPath, to: tempDir.path) else { return nil }

        // 2. 找到 .app 包
        guard let appName = try? FileManager.default.contentsOfDirectory(atPath: payloadDir.path).first(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        let appPath = payloadDir.appendingPathComponent(appName).path

        // 3. 签名
        guard signAppBundle(at: appPath, config: config) else { return nil }

        // 4. 重新打包为 IPA
        let signedName = "signed_\(Int(Date().timeIntervalSince1970))_\(URL(fileURLWithPath: ipaPath).lastPathComponent)"
        let signedDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Signed")
        try? FileManager.default.createDirectory(at: signedDir, withIntermediateDirectories: true)
        let signedPath = signedDir.appendingPathComponent(signedName).path

        guard zip(sourceDir: tempDir.path, output: signedPath) else { return nil }

        // 5. 保存历史
        HistoryStorage.save(ipaName: URL(fileURLWithPath: ipaPath).lastPathComponent, config: config, signedPath: signedPath)
        return signedPath
    }

    // MARK: - 辅助函数
    private static func buildEntitlementsContent(config: SignConfig) -> String? {
        if let custom = config.entitlementContent, !custom.isEmpty {
            return custom
        }
        if config.platformApp || !config.teamID.isEmpty {
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n"
            if config.platformApp { xml += "\t<key>platform-application</key>\n\t<true/>\n" }
            if !config.teamID.isEmpty {
                xml += "\t<key>com.apple.developer.team-identifier</key>\n\t<string>\(config.teamID)</string>\n"
                xml += "\t<key>application-identifier</key>\n\t<string>\(config.teamID).*</string>\n"
                xml += "\t<key>com.apple.private.security.no-container</key>\n\t<true/>\n"
                xml += "\t<key>com.apple.private.skip-library-validation</key>\n\t<true/>\n"
            }
            xml += "</dict>\n</plist>"
            return xml
        }
        return nil
    }

    private static func modifyInfoPlist(at appPath: String, config: SignConfig) {
        let infoPlist = appPath + "/Info.plist"
        guard var info = NSDictionary(contentsOf: infoPlist) as? [String: Any] else { return }

        if let bid = config.bundleId { info["CFBundleIdentifier"] = bid }
        if let dn = config.displayName {
            info["CFBundleDisplayName"] = dn
            info["CFBundleName"] = dn
        }
        if config.removeDeviceLimits {
            info.removeValue(forKey: "UISupportedDevices")
            info["MinimumOSVersion"] = "14.0"
        }
        (info as NSDictionary).write(to: infoPlist, atomically: true)
    }

    private static func unzip(_ ipaPath: String, to dest: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-o", "-q", ipaPath, "-d", dest]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        return FileManager.default.fileExists(atPath: dest + "/Payload")
    }

    private static func zip(sourceDir: String, output: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.arguments = ["-qr", output, "Payload"]
        task.currentDirectoryURL = URL(fileURLWithPath: sourceDir)
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        return FileManager.default.fileExists(atPath: output)
    }
}

// MARK: - 历史记录存储
struct HistoryStorage {
    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("History/sign_history.json")

    static func save(ipaName: String, config: SigningService.SignConfig, signedPath: String) {
        var records = load()
        let size: String = {
            guard let attr = try? FileManager.default.attributesOfItem(atPath: signedPath),
                  let s = attr[.size] as? Int64 else { return "" }
            return ByteCountFormatter.string(fromByteCount: s, countStyle: .file)
        }()
        let record = HistoryRecord(date: Date(), ipaName: ipaName,
                                   engine: config.engine.rawValue,
                                   mode: config.mode.rawValue,
                                   size: size, signedPath: signedPath)
        records.insert(record, at: 0)
        if records.count > 50 { records = Array(records.prefix(50)) }
        if let data = try? JSONEncoder().encode(records) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    /// 批量保存（HistoryViewController 调用）
    static func save(records: [HistoryRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    static func load() -> [HistoryRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([HistoryRecord].self, from: data)
        else { return [] }
        return records
    }
}

struct HistoryRecord: Codable {
    var id = UUID()
    var date: Date
    var ipaName: String
    var engine: String
    var mode: String
    var size: String
    var signedPath: String
}