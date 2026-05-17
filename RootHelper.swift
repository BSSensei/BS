import UIKit

class RootHelper {
    
    static var isRoot: Bool {
        getuid() == 0
    }
    
    static var isTrollStore: Bool {
        let testPath = "/var/mobile/Library/Preferences/.permanentstore_test"
        let success = FileManager.default.createFile(atPath: testPath, contents: nil, attributes: nil)
        if success {
            try? FileManager.default.removeItem(atPath: testPath)
        }
        return success
    }
    
    static var hasSystemPrivileges: Bool {
        isRoot || isTrollStore
    }
    
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
    
    static func rebuildIconCache() {
        guard hasSystemPrivileges else { return }
        execute("uicache -a")
    }
    
    static func restartSpringBoard() {
        guard hasSystemPrivileges else { return }
        execute("killall -9 SpringBoard")
    }
    
    static func cleanTemp() {
        let tempDir = NSTemporaryDirectory()
        if let files = try? FileManager.default.contentsOfDirectory(atPath: tempDir) {
            for file in files {
                try? FileManager.default.removeItem(atPath: tempDir + "/" + file)
            }
        }
    }
}
