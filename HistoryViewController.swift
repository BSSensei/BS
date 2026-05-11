// Sources/HistoryViewController.swift
import UIKit

class HistoryViewController: UIViewController {
    
    private var records: [HistoryRecord] = []
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "历史记录"
        view.backgroundColor = Theme.bg
        
        setupEmptyLabel()
        setupTableView()
        loadHistory()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadHistory()
    }
    
    private func setupEmptyLabel() {
        emptyLabel.text = "还没有签名的 IPA"
        emptyLabel.textColor = Theme.textSecondary
        emptyLabel.font = .systemFont(ofSize: 16, weight: .medium)
        emptyLabel.textAlignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
    
    private func setupTableView() {
        tableView.frame = view.bounds
        tableView.delegate = self
        tableView.dataSource = self
        tableView.backgroundColor = .clear
        tableView.separatorColor = Theme.separator
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "historyCell")
        view.addSubview(tableView)
    }
    
    private func loadHistory() {
        records = HistoryStorage.load()
        tableView.reloadData()
        emptyLabel.isHidden = !records.isEmpty
    }
}

// MARK: - UITableViewDataSource & Delegate
extension HistoryViewController: UITableViewDelegate, UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        records.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "historyCell", for: indexPath)
        let record = records[indexPath.row]
        
        cell.backgroundColor = UIColor(white: 0.1, alpha: 1)
        cell.textLabel?.textColor = .white
        cell.textLabel?.font = .systemFont(ofSize: 14)
        cell.detailTextLabel?.textColor = .gray
        cell.detailTextLabel?.font = .systemFont(ofSize: 12)
        
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        cell.textLabel?.text = record.ipaName
        cell.detailTextLabel?.text = "\(formatter.string(from: record.date))  \(record.engine)/\(record.mode)  \(record.size)"
        cell.accessoryType = .disclosureIndicator
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let record = records[indexPath.row]
        showOptions(for: record)
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let record = records[indexPath.row]
            if FileManager.default.fileExists(atPath: record.signedPath) {
                try? FileManager.default.removeItem(atPath: record.signedPath)
            }
            records.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            HistoryStorage.save(records: records)
        }
    }
    
    // MARK: - 操作菜单
    private func showOptions(for record: HistoryRecord) {
        let alert = UIAlertController(
            title: record.ipaName,
            message: "\(record.engine) / \(record.mode)\n\(record.size)",
            preferredStyle: .actionSheet
        )
        
        // 分享
        alert.addAction(UIAlertAction(title: "分享", style: .default) { [weak self] _ in
            self?.shareRecord(record)
        })
        
        // 安装 - 让用户选择方式
        alert.addAction(UIAlertAction(title: "安装…", style: .default) { [weak self] _ in
            self?.showInstallOptions(for: record)
        })
        
        // 删除
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.deleteRecord(record)
        })
        
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(alert, animated: true)
    }
    
    // MARK: - 安装方式选择
    private func showInstallOptions(for record: HistoryRecord) {
        let alert = UIAlertController(
            title: "选择安装方式",
            message: "IPA：\(record.ipaName)",
            preferredStyle: .actionSheet
        )
        
        alert.addAction(UIAlertAction(title: "itunesstored（巨魔商店）", style: .default) { [weak self] _ in
            self?.performInstall(record: record, method: .itunesstored)
        })
        
        alert.addAction(UIAlertAction(title: "系统直接安装", style: .default) { [weak self] _ in
            self?.performInstall(record: record, method: .systemInstall)
        })
        
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(alert, animated: true)
    }
    
    private func performInstall(record: HistoryRecord, method: InstallMethod) {
        guard RootHelper.hasSystemPrivileges else {
            let alert = UIAlertController(
                title: "权限不足",
                message: "安装需要巨魔商店或越狱环境",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "知道了", style: .default))
            present(alert, animated: true)
            return
        }
        
        Toast.show("正在安装…", on: view)
        
        InstallManager.shared.install(ipaPath: record.signedPath, method: method) { [weak self] result in
            guard let self = self else { return }
            
            if result.success {
                let alert = UIAlertController(title: "安装成功", message: result.message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好的", style: .default))
                self.present(alert, animated: true)
            } else {
                let alert = UIAlertController(title: "安装失败", message: result.message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "知道了", style: .default))
                self.present(alert, animated: true)
            }
        }
    }
    
    private func shareRecord(_ record: HistoryRecord) {
        let url = URL(fileURLWithPath: record.signedPath)
        let avc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = avc.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(avc, animated: true)
    }
    
    private func deleteRecord(_ record: HistoryRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            if FileManager.default.fileExists(atPath: record.signedPath) {
                try? FileManager.default.removeItem(atPath: record.signedPath)
            }
            records.remove(at: index)
            HistoryStorage.save(records: records)
            tableView.reloadData()
        }
    }
}