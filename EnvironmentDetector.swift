import Foundation

enum EnvironmentType {
    case trollStore
    case jailbroken
    case normal
}

class EnvironmentDetector {
    static let shared = EnvironmentDetector()

    var current: EnvironmentType {
        if hasTrollStore() { return .trollStore }
        if hasRootPrivileges() { return .jailbroken }
        return .normal
    }

    /// 检测是否安装 TrollStore
    private func hasTrollStore() -> Bool {
        FileManager.default.fileExists(
            atPath: "/var/containers/Bundle/Application/TrollStore/TrollStore.app"
        )
    }

    /// 检测是否拥有系统权限（越狱）
    private func hasRootPrivileges() -> Bool {
        getuid() == 0
    }
}
