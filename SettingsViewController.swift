// Sources/SettingsViewController.swift
import UIKit

class SettingsViewController: UIViewController {

    // MARK: - 数据
    private let sectionTitles = ["安装设置", "系统工具", "高级", "关于"]
    
    private let systemActions: [(title: String, icon: String, action: () -> Void)] = [
        ("刷新图标缓存", "arrow.triangle.2.circlepath", {
            RootHelper.execute("uicache -a")
            if let view = UIApplication.shared.windows.first?.rootViewController?.view {
                Toast.show("图标缓存已刷新", on: view)
            }
        }),
        ("重启主屏幕", "arrow.clockwise", {
            let alert = UIAlertController(title: "重启 SpringBoard", message: "确定重启主屏幕？", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "重启", style: .destructive, handler: { _ in
                RootHelper.execute("killall -9 SpringBoard")
            }))
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            if let topVC = UIApplication.shared.windows.first?.rootViewController {
                topVC.present(alert, animated: true)
            }
        }),
        ("注销设备", "lock.rotation", {
            let alert = UIAlertController(title: "注销", message: "确定注销到锁屏？", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "注销", style: .destructive, handler: { _ in
                RootHelper.execute("killall -9 loginwindow")
            }))
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            if let topVC = UIApplication.shared.windows.first?.rootViewController {
                topVC.present(alert, animated: true)
            }
        }),
        ("重建信任缓存", "shield.checkered", {
            RootHelper.execute("trustcaches rebuild")
            if let view = UIApplication.shared.windows.first?.rootViewController?.view {
                Toast.show("信任缓存已重建", on: view)
            }
        }),
        ("清理临时文件", "trash", {
            RootHelper.cleanTemp()
            if let view = UIApplication.shared.windows.first?.rootViewController?.view {
                Toast.show("临时文件已清理", on: view)
            }
        })
    ]

    // MARK: - UI 组件
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        view.backgroundColor = Theme.bg
        setupTableView()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.backgroundColor = Theme.bg
        tableView.backgroundColor = .clear
        tableView.reloadData()
    }

    private func setupTableView() {
        tableView.frame = view.bounds
        tableView.delegate = self
        tableView.dataSource = self
        tableView.backgroundColor = .clear
        tableView.separatorColor = Theme.separator
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "settingsCell")
        view.addSubview(tableView)
    }
}

// MARK: - UITableView 代理
extension SettingsViewController: UITableViewDelegate, UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        sectionTitles.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 1  // 默认安装方式
        case 1: return systemActions.count
        case 2: return 1  // 默认签名引擎
        case 3: return 1  // 关于
        default: return 0
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionTitles[section]
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "settingsCell", for: indexPath)
        cell.backgroundColor = UIColor(white: 0.1, alpha: 1)
        cell.textLabel?.textColor = .white
        cell.textLabel?.font = .systemFont(ofSize: 14)
        cell.detailTextLabel?.textColor = .gray
        cell.detailTextLabel?.font = .systemFont(ofSize: 12)

        switch indexPath.section {
        case 0:
            // 默认安装方式
            cell.textLabel?.text = "默认安装方式"
            cell.detailTextLabel?.text = InstallManager.shared.defaultMethod.description
            cell.imageView?.image = UIImage(systemName: InstallManager.shared.defaultMethod.icon)
            cell.imageView?.tintColor = Theme.accent
            cell.accessoryType = .disclosureIndicator
            
        case 1:
            let action = systemActions[indexPath.row]
            cell.textLabel?.text = action.title
            cell.imageView?.image = UIImage(systemName: action.icon)
            cell.imageView?.tintColor = Theme.accent
            cell.accessoryType = .disclosureIndicator
            cell.detailTextLabel?.text = nil
            
        case 2:
            cell.textLabel?.text = "默认签名引擎"
            cell.detailTextLabel?.text = UserDefaults.standard.string(forKey: "defaultSignEngine") ?? "ldid2"
            cell.accessoryType = .disclosureIndicator
            cell.imageView?.image = UIImage(systemName: "wrench.and.screwdriver.fill")
            cell.imageView?.tintColor = Theme.accent
            
        case 3:
            cell.textLabel?.text = "PermanentStore v1.0"
            cell.detailTextLabel?.text = "巨魔/越狱设备签名工具"
            cell.accessoryType = .none
            cell.imageView?.image = UIImage(systemName: "info.circle.fill")
            cell.imageView?.tintColor = .gray
            
        default:
            break
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        switch indexPath.section {
        case 0:
            showInstallMethodPicker()
            
        case 1:
            let action = systemActions[indexPath.row]
            if !RootHelper.hasSystemPrivileges && (action.title.contains("重启") || action.title.contains("注销")) {
                let alert = UIAlertController(title: "权限不足", message: "此操作需要越狱或巨魔环境。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "确定", style: .default))
                present(alert, animated: true)
                return
            }
            action.action()
            
        case 2:
            showEnginePicker()
            
        case 3:
            break
            
        default:
            break
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.section == 3 { return 60 }
        return 44
    }
    
    // MARK: - 选择器
    private func showInstallMethodPicker() {
        let alert = UIAlertController(title: "默认安装方式", message: "签名后优先使用此方式安装", preferredStyle: .actionSheet)
        
        for method in InstallMethod.allCases {
            let isCurrent = InstallManager.shared.defaultMethod == method
            alert.addAction(UIAlertAction(
                title: isCurrent ? "✓ \(method.description)" : method.description,
                style: .default
            ) { _ in
                InstallManager.shared.defaultMethod = method
                self.tableView.reloadData()
                if let view = self.view {
                    Toast.show("已设为：\(method.description)", on: view)
                }
            })
        }
        
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(alert, animated: true)
    }
    
    private func showEnginePicker() {
        let alert = UIAlertController(title: "选择默认引擎", message: nil, preferredStyle: .actionSheet)
        
        for engine in ["ldid2", "zsign"] {
            let current = UserDefaults.standard.string(forKey: "defaultSignEngine") ?? "ldid2"
            alert.addAction(UIAlertAction(
                title: current == engine ? "✓ \(engine)" : engine,
                style: .default
            ) { _ in
                UserDefaults.standard.set(engine, forKey: "defaultSignEngine")
                self.tableView.reloadData()
                if let view = self.view {
                    Toast.show("默认引擎：\(engine)", on: view)
                }
            })
        }
        
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(alert, animated: true)
    }
}