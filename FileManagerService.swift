import Foundation

struct FileManagerService {
    static func listDirectory(_ path: String) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return []
        }
        return items.sorted { 
            let isDir1 = isDirectory(path + "/" + $0)
            let isDir2 = isDirectory(path + "/" + $1)
            if isDir1 != isDir2 { return isDir1 }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }
    
    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }
    
    static func fileSize(at path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else {
            return "Unknown"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
    
    static func createDirectory(named name: String, at path: String) -> Bool {
        let newPath = path + "/" + name
        do {
            try FileManager.default.createDirectory(atPath: newPath, withIntermediateDirectories: false)
            return true
        } catch {
            return false
        }
    }
    
    static func createFile(named name: String, at path: String) -> Bool {
        let newPath = path + "/" + name
        return FileManager.default.createFile(atPath: newPath, contents: nil, attributes: nil)
    }
    
    static func destinationDir(for fileName: String, currentPath: String) -> String {
        return currentPath
    }
    
    static var docsDir: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }
    
    static var certsDir: String { docsDir + "/Certificates" }
    static var dylibsDir: String { docsDir + "/Dylibs" }
    static var ipasDir: String { docsDir + "/IPAs" }
    static var signedDir: String { docsDir + "/Signed" }
}
