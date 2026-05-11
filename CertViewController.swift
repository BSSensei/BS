import UIKit
import UniformTypeIdentifiers
import Security

class CertViewController: UIViewController {

    // MARK: - 数据
    private var certFiles: [String] = []
    private let certsDir: String = {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let path = docs + "/Certificates"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    // MARK: - UI 组件
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let outputTextView = UITextView()
    private let toolbar = UIToolbar()

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Certificates"
        view.backgroundColor = Theme.bg
        outputTextView.backgroundColor = UIColor(white: 0.12, alpha: 1.0)
        setupTableView()
        setupOutputView()
        setupToolbar()
        refreshCerts()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshCerts()
        view.backgroundColor = Theme.bg
        tableView.backgroundColor = .clear
    }

    // MARK: - UI 设置
    private func setupTableView() {
        tableView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height * 0.5)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.backgroundColor = .clear
        tableView.separatorColor = Theme.separator
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "certCell")
        view.addSubview(tableView)
    }

    private func setupOutputView() {
        let topY = view.bounds.height * 0.5
        let remainingHeight = view.bounds.height - topY - 44
        outputTextView.frame = CGRect(x: 10, y: topY + 5, width: view.bounds.width - 20, height: max(remainingHeight - 5, 60))
        outputTextView.font = .systemFont(ofSize: 10, design: .monospaced)
        outputTextView.isEditable = false
        outputTextView.textColor = .white
        outputTextView.layer.cornerRadius = 8
        outputTextView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.addSubview(outputTextView)
    }

    private func setupToolbar() {
        toolbar.frame = CGRect(x: 0, y: view.bounds.height - 44, width: view.bounds.width, height: 44)
        toolbar.barTintColor = UIColor(white: 0.07, alpha: 1)
        toolbar.tintColor = Theme.accent
        toolbar.items = [
            UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.down"), style: .plain, target: self, action: #selector(importCert)),
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: "Show Info", style: .plain, target: self, action: #selector(showCertInfo)),
        ]
        view.addSubview(toolbar)
    }

    // MARK: - 数据刷新
    private func refreshCerts() {
        certFiles = (try? FileManager.default.contentsOfDirectory(atPath: certsDir))?.filter { name in
            let ext = (name as NSString).pathExtension.lowercased()
            return ["p12", "cer", "crt", "key", "pem", "der"].contains(ext)
        } ?? []
        tableView.reloadData()
        if let firstItem = toolbar.items?.first {
            firstItem.title = "\(certFiles.count) certs"
        }
        view.backgroundColor = Theme.bg
        tableView.backgroundColor = .clear
    }

    // MARK: - 操作
    @objc private func importCert() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    @objc private func showCertInfo() {
        guard let selected = tableView.indexPathForSelectedRow?.row, selected < certFiles.count else {
            outputTextView.text = "Select a certificate first."
            return
        }
        let path = certsDir + "/" + certFiles[selected]
        let info = parseCertificate(at: path)
        outputTextView.text = info
    }

    // MARK: - 证书解析（基本查看功能）
    private func parseCertificate(at path: String) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return "Cannot read file" }

        var cert: SecCertificate?
        if let secCert = SecCertificateCreateWithData(nil, data as CFData) {
            cert = secCert
        } else if let pemString = String(data: data, encoding: .utf8),
                  let derData = Data(base64Encoded: pemString
                    .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                    .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
                    .replacingOccurrences(of: "\n", with: ""),
                    options: .ignoreUnknownCharacters) {
            cert = SecCertificateCreateWithData(nil, derData as CFData)
        }

        guard let cert = cert else { return "Invalid certificate file" }

        var result = "=== Certificate Info ===\n"
        if let summary = SecCertificateCopySubjectSummary(cert) {
            result += "Subject: \(summary)\n"
        }
        if let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
           let validity = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
           let number = validity["value"] as? NSNumber {
            let expireDate = Date(timeIntervalSinceReferenceDate: number.doubleValue)
            result += "Expires: \(expireDate)\n"
        }
        if let data = SecCertificateCopyData(cert) as Data? {
            result += "DER size: \(data.count) bytes\n"
        }
        return result
    }
}

// MARK: - UITableView 代理
extension CertViewController: UITableViewDelegate, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        certFiles.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "certCell", for: indexPath)
        let name = certFiles[indexPath.row]
        cell.textLabel?.text = name
        cell.textLabel?.textColor = .white
        cell.textLabel?.font = .systemFont(ofSize: 13)
        cell.backgroundColor = UIColor(white: 0.1, alpha: 1)
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        outputTextView.text = parseCertificate(at: certsDir + "/" + certFiles[indexPath.row])
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let path = certsDir + "/" + certFiles[indexPath.row]
            try? FileManager.default.removeItem(atPath: path)
            certFiles.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
        }
    }
}

// MARK: - UIDocumentPickerDelegate
extension CertViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            let dest = certsDir + "/" + url.lastPathComponent
            try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: dest))
            url.stopAccessingSecurityScopedResource()
        }
        refreshCerts()
    }
}