// Sources/SignViewController.swift
import UIKit
import UniformTypeIdentifiers

class SignViewController: UIViewController {

    // MARK: - 签名配置
    var config = SigningService.SignConfig()

    // MARK: - 数据源
    private var availableCerts: [String] = []
    private var availableProvisionings: [String] = []

    // MARK: - UI 组件
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    private let engineSegment = UISegmentedControl(items: SigningService.SignConfig.Engine.allCases.map { $0.rawValue })
    private let modeSegment = UISegmentedControl(items: SigningService.SignConfig.Mode.allCases.map { $0.rawValue })

    private var ipaLabel: UILabel!
    private var certTableView: UITableView!
    private var provTableView: UITableView!
    private var outputTextView: UITextView!

    private var teamIDField: UITextField!
    private var bundleIDField: UITextField!
    private var displayNameField: UITextField!
    private var passwordField: UITextField!
    private var entTextView: UITextView!

    private var switchPlatform: UISwitch!
    private var switchRemoveLimits: UISwitch!

    private var signButton: UIButton!
    private var installButton: UIButton!
    private var progressBar: UIProgressView!
    
    private var lastSignedPath: String?

    // MARK: - 布局常量
    private let pad: CGFloat = 16
    private var contentWidth: CGFloat { view.bounds.width - pad * 2 }

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "签名"
        view.backgroundColor = Theme.bg
        setupScrollView()
        refreshData()
        buildUI()
        
        // 从设置读取默认引擎
        if let savedEngine = UserDefaults.standard.string(forKey: "defaultSignEngine") {
            config.engine = savedEngine == "zsign" ? .zsign : .ldid2
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(openIPA(_:)), name: NSNotification.Name("OpenIPA"), object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshData()
        updateCertTable()
        updateProvisioningTable()
    }

    // MARK: - 数据刷新
    private func refreshData() {
        let certsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Certificates").path
        try? FileManager.default.createDirectory(atPath: certsDir, withIntermediateDirectories: true)
        
        availableCerts = (try? FileManager.default.contentsOfDirectory(atPath: certsDir))?.filter { name in
            let ext = (name as NSString).pathExtension.lowercased()
            return ["p12", "crt", "key", "pem", "cer", "der"].contains(ext)
        } ?? []
        
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        availableProvisionings = (try? FileManager.default.contentsOfDirectory(atPath: docsDir))?.filter {
            $0.hasSuffix(".mobileprovision")
        } ?? []
    }

    // MARK: - UI 构建
    private func setupScrollView() {
        scrollView.frame = view.bounds
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
    }

    private func buildUI() {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 16

        // ---- 引擎选择 ----
        addSectionTitle("签名引擎", at: &y)
        engineSegment.frame = CGRect(x: pad, y: y, width: contentWidth, height: 32)
        engineSegment.selectedSegmentIndex = (config.engine == .ldid2) ? 0 : 1
        engineSegment.addTarget(self, action: #selector(engineChanged(_:)), for: .valueChanged)
        styleSegment(engineSegment)
        contentView.addSubview(engineSegment)
        y += 44

        // ---- 模式选择 ----
        addSectionTitle("签名模式", at: &y)
        modeSegment.frame = CGRect(x: pad, y: y, width: contentWidth, height: 32)
        modeSegment.selectedSegmentIndex = (config.mode == .adhoc) ? 0 : 1
        modeSegment.addTarget(self, action: #selector(modeChanged(_:)), for: .valueChanged)
        styleSegment(modeSegment)
        contentView.addSubview(modeSegment)
        y += 44

        // ---- IPA 选择 ----
        addSectionTitle("IPA 文件", at: &y)
        let ipaBtn = makeButton("选择 IPA 文件", action: #selector(selectIPA))
        ipaBtn.frame = CGRect(x: pad, y: y, width: contentWidth, height: 42)
        contentView.addSubview(ipaBtn)
        y += 50
        ipaLabel = UILabel(frame: CGRect(x: pad, y: y, width: contentWidth, height: 20))
        ipaLabel.text = config.ipaPath ?? "未选择 IPA"
        ipaLabel.textColor = config.ipaPath != nil ? .white : .gray
        ipaLabel.font = .systemFont(ofSize: 13)
        ipaLabel.numberOfLines = 0
        contentView.addSubview(ipaLabel)
        y += 24

        // ---- 证书密码 ----
        if config.mode == .real {
            addSectionTitle("证书密码", at: &y)
            passwordField = UITextField(frame: CGRect(x: pad, y: y, width: contentWidth, height: 36))
            passwordField.borderStyle = .roundedRect
            passwordField.backgroundColor = .darkGray
            passwordField.textColor = .white
            passwordField.placeholder = "密码（默认：troll）"
            passwordField.text = config.certPassword
            passwordField.isSecureTextEntry = true
            passwordField.returnKeyType = .done
            passwordField.delegate = self
            passwordField.addTarget(self, action: #selector(passwordChanged(_:)), for: .editingChanged)
            
            // 显示/隐藏密码按钮
            let showHideBtn = UIButton(type: .system)
            showHideBtn.setImage(UIImage(systemName: "eye"), for: .normal)
            showHideBtn.tintColor = .gray
            showHideBtn.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
            showHideBtn.addTarget(self, action: #selector(togglePasswordVisibility), for: .touchUpInside)
            passwordField.rightView = showHideBtn
            passwordField.rightViewMode = .always
            
            contentView.addSubview(passwordField)
            y += 46
        }

        // ---- 证书列表 ----
        if config.mode == .real {
            addSectionTitle("选择证书", at: &y)
            if availableCerts.isEmpty {
                let emptyLabel = UILabel(frame: CGRect(x: pad, y: y, width: contentWidth, height: 36))
                emptyLabel.text = "没有证书，请先导入 .p12 文件"
                emptyLabel.textColor = .gray
                emptyLabel.font = .systemFont(ofSize: 13)
                contentView.addSubview(emptyLabel)
                y += 40
            } else {
                let certTableHeight = min(CGFloat(availableCerts.count * 44), 200)
                certTableView = UITableView(frame: CGRect(x: pad, y: y, width: contentWidth, height: certTableHeight))
                certTableView.delegate = self
                certTableView.dataSource = self
                certTableView.backgroundColor = .clear
                certTableView.tag = 1
                certTableView.isScrollEnabled = false
                certTableView.register(UITableViewCell.self, forCellReuseIdentifier: "certCell")
                contentView.addSubview(certTableView)
                y += certTableHeight + 8
            }
        }

        // ---- 描述文件列表 ----
        if config.mode == .real && config.engine == .zsign {
            addSectionTitle("描述文件（可选）", at: &y)
            if availableProvisionings.isEmpty {
                let emptyLabel = UILabel(frame: CGRect(x: pad, y: y, width: contentWidth, height: 36))
                emptyLabel.text = "没有描述文件"
                emptyLabel.textColor = .gray
                emptyLabel.font = .systemFont(ofSize: 13)
                contentView.addSubview(emptyLabel)
                y += 40
            } else {
                let provTableHeight = min(CGFloat(availableProvisionings.count * 44), 120)
                provTableView = UITableView(frame: CGRect(x: pad, y: y, width: contentWidth, height: provTableHeight))
                provTableView.delegate = self
                provTableView.dataSource = self
                provTableView.backgroundColor = .clear
                provTableView.tag = 2
                provTableView.isScrollEnabled = false
                provTableView.register(UITableViewCell.self, forCellReuseIdentifier: "provCell")
                contentView.addSubview(provTableView)
                y += provTableHeight + 8
            }
        }

        // ---- Team ID / Ad-hoc 选项 ----
        if config.mode == .adhoc {
            addSectionTitle("Ad-hoc 选项", at: &y)
            let teamLabel = UILabel(frame: CGRect(x: pad, y: y, width: contentWidth, height: 20))
            teamLabel.text = "Team ID（可选）"
            teamLabel.textColor = .white
            teamLabel.font = .systemFont(ofSize: 13)
            contentView.addSubview(teamLabel)
            y += 24

            teamIDField = UITextField(frame: CGRect(x: pad, y: y, width: contentWidth, height: 36))
            teamIDField.borderStyle = .roundedRect
            teamIDField.backgroundColor = .darkGray
            teamIDField.textColor = .white
            teamIDField.placeholder = "例如：0000000000"
            teamIDField.text = config.teamID
            teamIDField.returnKeyType = .done
            teamIDField.delegate = self
            teamIDField.addTarget(self, action: #selector(teamIDChanged(_:)), for: .editingChanged)
            contentView.addSubview(teamIDField)
            y += 46

            switchPlatform = makeSwitchRow("Platform Application", isOn: config.platformApp) { [weak self] on in
                self?.config.platformApp = on
            }
            switchPlatform.frame = CGRect(x: pad, y: y, width: contentWidth, height: 46)
            contentView.addSubview(switchPlatform)
            y += 52
        }

        // ---- Bundle ID & Display Name ----
        addSectionTitle("应用修改（可选）", at: &y)
        
        let bidLabel = UILabel(frame: CGRect(x: pad, y: y, width: contentWidth, height: 20))
        bidLabel.text = "新 Bundle ID"
        bidLabel.textColor = .white
        bidLabel.font = .systemFont(ofSize: 13)
        contentView.addSubview(bidLabel)
        y += 24
        
        bundleIDField = UITextField(frame: CGRect(x: pad, y: y, width: contentWidth, height: 36))
        bundleIDField.borderStyle = .roundedRect
        bundleIDField.backgroundColor = .darkGray
        bundleIDField.textColor = .white
        bundleIDField.placeholder = "com.example.app"
        bundleIDField.text = config.bundleId
        bundleIDField.returnKeyType = .done
        bundleIDField.delegate = self
        bundleIDField.addTarget(self, action: #selector(bundleIDChanged(_:)), for: .editingChanged)
        contentView.addSubview(bundleIDField)
        y += 46

        let dnLabel = UILabel(frame: CGRect(x: pad, y: y, width: contentWidth, height: 20))
        dnLabel.text = "新显示名称"
        dnLabel.textColor = .white
        dnLabel.font = .systemFont(ofSize: 13)
        contentView.addSubview(dnLabel)
        y += 24
        
        displayNameField = UITextField(frame: CGRect(x: pad, y: y, width: contentWidth, height: 36))
        displayNameField.borderStyle = .roundedRect
        displayNameField.backgroundColor = .darkGray
        displayNameField.textColor = .white
        displayNameField.placeholder = "我的应用"
        displayNameField.text = config.displayName
        displayNameField.returnKeyType = .done
        displayNameField.delegate = self
        displayNameField.addTarget(self, action: #selector(displayNameChanged(_:)), for: .editingChanged)
        contentView.addSubview(displayNameField)
        y += 48

        // ---- 移除设备限制 ----
        switchRemoveLimits = makeSwitchRow("移除设备限制", isOn: config.removeDeviceLimits) { [weak self] on in
            self?.config.removeDeviceLimits = on
        }
        switchRemoveLimits.frame = CGRect(x: pad, y: y, width: contentWidth, height: 46)
        contentView.addSubview(switchRemoveLimits)
        y += 52

        // ---- 自定义 Entitlements ----
        addSectionTitle("自定义 Entitlements（plist XML）", at: &y)
        entTextView = UITextView(frame: CGRect(x: pad, y: y, width: contentWidth, height: 120))
        entTextView.font = .systemFont(ofSize: 10, design: .monospaced)
        entTextView.backgroundColor = UIColor(white: 0.12, alpha: 1)
        entTextView.textColor = .white
        entTextView.layer.cornerRadius = 8
        entTextView.text = config.entitlementContent
        entTextView.delegate = self
        contentView.addSubview(entTextView)
        y += 128

        // ---- 进度条 ----
        progressBar = UIProgressView(progressViewStyle: .default)
        progressBar.frame = CGRect(x: pad, y: y, width: contentWidth, height: 4)
        progressBar.progressTintColor = Theme.accent
        progressBar.isHidden = true
        contentView.addSubview(progressBar)
        y += 16

        // ---- 签名按钮 ----
        signButton = UIButton(type: .system)
        signButton.frame = CGRect(x: pad, y: y, width: contentWidth, height: 50)
        signButton.setTitle("开始签名", for: .normal)
        signButton.backgroundColor = Theme.accent
        signButton.setTitleColor(.white, for: .normal)
        signButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        signButton.layer.cornerRadius = 14
        signButton.addTarget(self, action: #selector(startSigning), for: .touchUpInside)
        contentView.addSubview(signButton)
        y += 58

        // ---- 安装按钮 ----
        installButton = UIButton(type: .system)
        installButton.frame = CGRect(x: pad, y: y, width: contentWidth, height: 44)
        installButton.setTitle("安装已签名的 IPA…", for: .normal)
        installButton.backgroundColor = UIColor.systemGreen
        installButton.setTitleColor(.white, for: .normal)
        installButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        installButton.layer.cornerRadius = 12
        installButton.addTarget(self, action: #selector(installLastSigned), for: .touchUpInside)
        installButton.isHidden = true
        contentView.addSubview(installButton)
        y += 52

        // ---- 输出 ----
        addSectionTitle("输出日志", at: &y)
        outputTextView = UITextView(frame: CGRect(x: pad, y: y, width: contentWidth, height: 200))
        outputTextView.font = .systemFont(ofSize: 10, design: .monospaced)
        outputTextView.isEditable = false
        outputTextView.backgroundColor = UIColor(white: 0.12, alpha: 1)
        outputTextView.textColor = .white
        outputTextView.layer.cornerRadius = 8
        outputTextView.text = ""
        contentView.addSubview(outputTextView)
        y += 216

        contentView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: y + 40)
        scrollView.contentSize = contentView.frame.size
    }

    // MARK: - UI 更新
    private func updateCertTable() {
        certTableView?.reloadData()
        if let ct = certTableView {
            let h = min(CGFloat(availableCerts.count * 44), 200)
            ct.frame.size.height = h
        }
    }

    private func updateProvisioningTable() {
        provTableView?.reloadData()
        if let pt = provTableView {
            let h = min(CGFloat(availableProvisionings.count * 44), 120)
            pt.frame.size.height = h
        }
    }

    // MARK: - Actions
    @objc private func engineChanged(_ sender: UISegmentedControl) {
        config.engine = sender.selectedSegmentIndex == 0 ? .ldid2 : .zsign
        buildUI()
    }

    @objc private func modeChanged(_ sender: UISegmentedControl) {
        config.mode = sender.selectedSegmentIndex == 0 ? .adhoc : .real
        buildUI()
    }

    @objc private func selectIPA() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.delegate = self
        picker.view.tag = 100
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    @objc private func startSigning() {
        guard let ipaPath = config.ipaPath else {
            outputTextView.text = "❌ 请先选择 IPA 文件"
            return
        }
        if config.mode == .real && config.certPath == nil {
            outputTextView.text = "❌ 真签名模式需要选择证书"
            return
        }

        outputTextView.text = "🔐 正在签名…\n"
        signButton.isEnabled = false
        installButton.isHidden = true
        progressBar.isHidden = false
        progressBar.progress = 0.0
        
        // 动画进度
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self, !self.progressBar.isHidden else {
                timer.invalidate()
                return
            }
            if self.progressBar.progress < 0.9 {
                self.progressBar.progress += 0.05
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let signedPath = SigningService.signIPA(config: self.config)
            
            DispatchQueue.main.async {
                self.signButton.isEnabled = true
                self.progressBar.isHidden = true
                
                if let path = signedPath {
                    self.lastSignedPath = path
                    self.outputTextView.text += "✅ 签名成功！\n📁 \(path)\n"
                    self.installButton.isHidden = false
                    self.installButton.setTitle("安装已签名的 IPA…", for: .normal)
                    
                    // 自动弹出操作选择
                    self.showPostSignOptions(signedPath: path)
                } else {
                    self.outputTextView.text += "❌ 签名失败\n"
                    self.installButton.isHidden = true
                }
            }
        }
    }
    
    @objc private func installLastSigned() {
        guard let path = lastSignedPath else { return }
        showInstallForSigned(signedPath: path)
    }
    
    // MARK: - 签名后操作
    private func showPostSignOptions(signedPath: String) {
        let alert = UIAlertController(
            title: "签名完成",
            message: "对已签名的 IPA 执行操作",
            preferredStyle: .actionSheet
        )
        
        alert.addAction(UIAlertAction(title: "📤 分享", style: .default) { [weak self] _ in
            self?.shareSignedIPA(path: signedPath)
        })
        
        alert.addAction(UIAlertAction(title: "📲 安装…", style: .default) { [weak self] _ in
            self?.showInstallForSigned(signedPath: signedPath)
        })
        
        alert.addAction(UIAlertAction(title: "✕ 关闭", style: .cancel))
        
        if let pop = alert.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(alert, animated: true)
    }
    
    private func showInstallForSigned(signedPath: String) {
        let alert = UIAlertController(
            title: "选择安装方式",
            message: nil,
            preferredStyle: .actionSheet
        )
        
        alert.addAction(UIAlertAction(
            title: "📦 itunesstored（巨魔商店）",
            style: .default
        ) { [weak self] _ in
            self?.installSigned(path: signedPath, method: .itunesstored)
        })
        
        alert.addAction(UIAlertAction(
            title: "⚙️ 系统直接安装",
            style: .default
        ) { [weak self] _ in
            self?.installSigned(path: signedPath, method: .systemInstall)
        })
        
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        
        if let pop = alert.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(alert, animated: true)
    }
    
    private func installSigned(path: String, method: InstallMethod) {
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
        
        outputTextView.text += "\n📲 正在安装（\(method.description)）…\n"
        installButton.isEnabled = false
        progressBar.isHidden = false
        progressBar.progress = 0.3
        
        InstallManager.shared.install(ipaPath: path, method: method) { [weak self] result in
            guard let self = self else { return }
            
            self.installButton.isEnabled = true
            self.progressBar.isHidden = true
            
            if result.success {
                self.outputTextView.text += "✅ 安装成功！（耗时 \(String(format: "%.1f", result.duration)) 秒）\n\(result.message)\n"
            } else {
                self.outputTextView.text += "❌ 安装失败\n\(result.message)\n"
            }
        }
    }
    
    private func shareSignedIPA(path: String) {
        let url = URL(fileURLWithPath: path)
        let avc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = avc.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(avc, animated: true)
    }

    // MARK: - 文本字段变化
    @objc private func teamIDChanged(_ tf: UITextField) { config.teamID = tf.text ?? "" }
    @objc private func bundleIDChanged(_ tf: UITextField) { config.bundleId = tf.text?.isEmpty == true ? nil : tf.text }
    @objc private func displayNameChanged(_ tf: UITextField) { config.displayName = tf.text?.isEmpty == true ? nil : tf.text }
    @objc private func passwordChanged(_ tf: UITextField) { config.certPassword = tf.text ?? "troll" }
    
    @objc private func togglePasswordVisibility() {
        passwordField.isSecureTextEntry.toggle()
        let btn = passwordField.rightView as? UIButton
        let imageName = passwordField.isSecureTextEntry ? "eye" : "eye.slash"
        btn?.setImage(UIImage(systemName: imageName), for: .normal)
    }

    @objc private func openIPA(_ notification: Notification) {
        if let path = notification.userInfo?["path"] as? String {
            config.ipaPath = path
            ipaLabel?.text = path
            ipaLabel?.textColor = .white
        }
    }

    // MARK: - UI Helpers
    private func addSectionTitle(_ text: String, at y: inout CGFloat) {
        let label = UILabel(frame: CGRect(x: pad, y: y, width: contentWidth, height: 20))
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        contentView.addSubview(label)
        y += 32
    }

    private func makeButton(_ title: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.backgroundColor = Theme.card
        btn.setTitleColor(Theme.accent, for: .normal)
        btn.contentHorizontalAlignment = .left
        btn.titleEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
        btn.layer.cornerRadius = 10
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    private func makeSwitchRow(_ title: String, isOn: Bool, action: @escaping (Bool) -> Void) -> UIView {
        let row = UIView()
        row.backgroundColor = Theme.card
        row.layer.cornerRadius = 10

        let label = UILabel()
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)

        let sw = UISwitch()
        sw.isOn = isOn
        sw.onTintColor = Theme.accent
        sw.translatesAutoresizingMaskIntoConstraints = false
        sw.addAction(UIAction { _ in action(sw.isOn) }, for: .valueChanged)
        row.addSubview(sw)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            sw.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            sw.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func styleSegment(_ seg: UISegmentedControl) {
        seg.backgroundColor = Theme.card
        seg.selectedSegmentTintColor = Theme.accent
        seg.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        seg.setTitleTextAttributes([.foregroundColor: UIColor.gray], for: .normal)
    }
}

// MARK: - UITableView DataSource & Delegate
extension SignViewController: UITableViewDelegate, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if tableView.tag == 1 { return availableCerts.count }
        if tableView.tag == 2 { return availableProvisionings.count }
        return 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: tableView.tag == 1 ? "certCell" : "provCell", for: indexPath)
        cell.backgroundColor = UIColor(white: 0.08, alpha: 1)
        cell.textLabel?.textColor = .white
        cell.textLabel?.font = .systemFont(ofSize: 13)
        cell.detailTextLabel?.textColor = .gray
        cell.detailTextLabel?.font = .systemFont(ofSize: 11)

        if tableView.tag == 1 {
            let name = availableCerts[indexPath.row]
            cell.textLabel?.text = name
            cell.imageView?.image = UIImage(systemName: "doc.badge.key")
            cell.imageView?.tintColor = .systemYellow
            
            let certPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Certificates/\(name)").path
            cell.accessoryType = (config.certPath == certPath) ? .checkmark : .none
        } else if tableView.tag == 2 {
            let name = availableProvisionings[indexPath.row]
            cell.textLabel?.text = name
            cell.imageView?.image = UIImage(systemName: "doc.badge.gearshape")
            cell.imageView?.tintColor = .systemGreen
            
            let provPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(name).path
            cell.accessoryType = (config.provPath == provPath) ? .checkmark : .none
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if tableView.tag == 1 {
            let name = availableCerts[indexPath.row]
            config.certPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Certificates/\(name)").path
            updateCertTable()
            outputTextView.text = "✅ 已选择证书: \(name)\n"
        } else if tableView.tag == 2 {
            let name = availableProvisionings[indexPath.row]
            config.provPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(name).path
            updateProvisioningTable()
            outputTextView.text = "✅ 已选择描述文件: \(name)\n"
        }
    }
}

// MARK: - UIDocumentPickerDelegate
extension SignViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        if controller.view.tag == 100 {
            config.ipaPath = url.path
            ipaLabel.text = url.path
            ipaLabel.textColor = .white
            outputTextView.text = "📦 已选择 IPA: \(url.lastPathComponent)\n"
        }
    }
}

// MARK: - UITextFieldDelegate, UITextViewDelegate
extension SignViewController: UITextFieldDelegate, UITextViewDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        config.entitlementContent = textView.text
    }
}