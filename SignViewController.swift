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
    private var pseudoSwitch: UISwitch!
    private var pseudoLabel: UILabel!

    // 动态控件（将根据引擎/模式重新创建）
    private var teamIDField: UITextField?
    private var passwordField: UITextField?
    private var certTableView: UITableView?
    private var provTableView: UITableView?
    private var zsignAdhocSwitch: UISwitch?   // zsign 伪签名专用开关

    private var ipaLabel: UILabel!
    private var outputTextView: UITextView!

    private var bundleIDField: UITextField!
    private var displayNameField: UITextField!
    private var entTextView: UITextView!

    private var switchPlatform: UISwitch?
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
        loadDefaultPresets()
        refreshData()
        buildUI()

        NotificationCenter.default.addObserver(self, selector: #selector(openIPA(_:)), name: NSNotification.Name("OpenIPA"), object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshData()
        updateCertTable()
        updateProvisioningTable()
    }

    // MARK: - 读取用户预设
    private func loadDefaultPresets() {
        let defaultEngine = UserDefaults.standard.string(forKey: "defaultSignEngine") ?? "ldid2"
        config.engine = defaultEngine == "zsign" ? .zsign : .ldid2

        let defaultPseudo = UserDefaults.standard.bool(forKey: "defaultPseudoMode")
        config.mode = defaultPseudo ? .adhoc : .real

        if let defaultTeamID = UserDefaults.standard.string(forKey: "defaultTeamID"), !defaultTeamID.isEmpty {
            config.teamID = defaultTeamID
        }
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

    // MARK: - UI 设置
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

        // ---- 伪签名模式开关（卡片样式）----
        let modeCard = UIView(frame: CGRect(x: pad, y: y, width: contentWidth, height: 52))
        modeCard.backgroundColor = Theme.card
        modeCard.layer.cornerRadius = 12

        let modeLabel = UILabel()
        modeLabel.text = "伪签名模式"
        modeLabel.textColor = .white
        modeLabel.font = .systemFont(ofSize: 15, weight: .medium)
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        modeCard.addSubview(modeLabel)

        pseudoSwitch = UISwitch()
        pseudoSwitch.isOn = (config.mode == .adhoc)
        pseudoSwitch.onTintColor = Theme.accent
        pseudoSwitch.addTarget(self, action: #selector(pseudoSwitchChanged(_:)), for: .valueChanged)
        pseudoSwitch.translatesAutoresizingMaskIntoConstraints = false
        modeCard.addSubview(pseudoSwitch)

        NSLayoutConstraint.activate([
            modeLabel.leadingAnchor.constraint(equalTo: modeCard.leadingAnchor, constant: 16),
            modeLabel.centerYAnchor.constraint(equalTo: modeCard.centerYAnchor),
            pseudoSwitch.trailingAnchor.constraint(equalTo: modeCard.trailingAnchor, constant: -16),
            pseudoSwitch.centerYAnchor.constraint(equalTo: modeCard.centerYAnchor)
        ])
        contentView.addSubview(modeCard)
        y += 60

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

        // ---- 真签名模式通用控件（密码 + 证书）----
        if config.mode == .real {
            // 证书密码
            addSectionTitle("证书密码", at: &y)
            let pwdField = UITextField(frame: CGRect(x: pad, y: y, width: contentWidth, height: 36))
            pwdField.borderStyle = .roundedRect
            pwdField.backgroundColor = .darkGray
            pwdField.textColor = .white
            pwdField.placeholder = "密码（默认：troll）"
            pwdField.text = config.certPassword
            pwdField.isSecureTextEntry = true
            pwdField.returnKeyType = .done
            pwdField.delegate = self
            pwdField.addTarget(self, action: #selector(passwordChanged(_:)), for: .editingChanged)

            let showHideBtn = UIButton(type: .system)
            showHideBtn.setImage(UIImage(systemName: "eye"), for: .normal)
            showHideBtn.tintColor = .gray
            showHideBtn.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
            showHideBtn.addTarget(self, action: #selector(togglePasswordVisibility), for: .touchUpInside)
            pwdField.rightView = showHideBtn
            pwdField.rightViewMode = .always

            contentView.addSubview(pwdField)
            passwordField = pwdField
            y += 46

            // 证书列表
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
                let certTV = UITableView(frame: CGRect(x: pad, y: y, width: contentWidth, height: certTableHeight))
                certTV.delegate = self
                certTV.dataSource = self
                certTV.backgroundColor = .clear
                certTV.tag = 1
                certTV.isScrollEnabled = false
                certTV.register(UITableViewCell.self, forCellReuseIdentifier: "certCell")
                contentView.addSubview(certTV)
                certTableView = certTV
                y += certTableHeight + 8
            }
        }

        // ---- 引擎专属控件 ----
        if config.mode == .adhoc {
            // 伪签名模式
            if config.engine == .ldid2 {
                addLdid2AdhocOptions(at: &y)
            } else if config.engine == .zsign {
                addZsignAdhocOptions(at: &y)
            }
        } else {
            // 真签名模式：zsign 需要描述文件
            if config.engine == .zsign {
                addProvisioningTable(at: &y)
            }
        }

        // ---- 通用修改选项 ----
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

        // 移除设备限制
        let removeLimitRow = makeSwitchRow("移除设备限制", isOn: config.removeDeviceLimits) { [weak self] on in
            self?.config.removeDeviceLimits = on
        }
        removeLimitRow.frame = CGRect(x: pad, y: y, width: contentWidth, height: 46)
        contentView.addSubview(removeLimitRow)
        switchRemoveLimits = removeLimitRow.subviews.compactMap { $0 as? UISwitch }.first
        y += 52

        // 自定义 Entitlements
        addSectionTitle("自定义 Entitlements（plist XML）", at: &y)
        let textView = UITextView(frame: CGRect(x: pad, y: y, width: contentWidth, height: 120))
        textView.font = .systemFont(ofSize: 10, design: .monospaced)
        textView.backgroundColor = UIColor(white: 0.12, alpha: 1)
        textView.textColor = .white
        textView.layer.cornerRadius = 8
        textView.text = config.entitlementContent
        textView.delegate = self
        contentView.addSubview(textView)
        entTextView = textView
        y += 128

        // 进度条
        progressBar = UIProgressView(progressViewStyle: .default)
        progressBar.frame = CGRect(x: pad, y: y, width: contentWidth, height: 4)
        progressBar.progressTintColor = Theme.accent
        progressBar.isHidden = true
        contentView.addSubview(progressBar)
        y += 16

        // 签名按钮
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

        // 安装按钮
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

        // 输出日志
        addSectionTitle("输出日志", at: &y)
        let outView = UITextView(frame: CGRect(x: pad, y: y, width: contentWidth, height: 200))
        outView.font = .systemFont(ofSize: 10, design: .monospaced)
        outView.isEditable = false
        outView.backgroundColor = UIColor(white: 0.12, alpha: 1)
        outView.textColor = .white
        outView.layer.cornerRadius = 8
        outView.text = ""
        contentView.addSubview(outView)
        outputTextView = outView
        y += 216

        contentView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: y + 40)
        scrollView.contentSize = contentView.frame.size
    }

    // MARK: - 引擎专属选项构建
    private func addLdid2AdhocOptions(at y: inout CGFloat) {
        addSectionTitle("ldid2 伪签名选项", at: &y)

        let teamLabel = UILabel(frame: CGRect(x: pad, y: y, width: contentWidth, height: 20))
        teamLabel.text = "Team ID（可选）"
        teamLabel.textColor = .white
        teamLabel.font = .systemFont(ofSize: 13)
        contentView.addSubview(teamLabel)
        y += 24

        let tf = UITextField(frame: CGRect(x: pad, y: y, width: contentWidth, height: 36))
        tf.borderStyle = .roundedRect
        tf.backgroundColor = .darkGray
        tf.textColor = .white
        tf.placeholder = "例如：0000000000"
        tf.text = config.teamID
        tf.returnKeyType = .done
        tf.delegate = self
        tf.addTarget(self, action: #selector(teamIDChanged(_:)), for: .editingChanged)
        contentView.addSubview(tf)
        teamIDField = tf
        y += 46

        let platformRow = makeSwitchRow("Platform Application", isOn: config.platformApp) { [weak self] on in
            self?.config.platformApp = on
        }
        platformRow.frame = CGRect(x: pad, y: y, width: contentWidth, height: 46)
        contentView.addSubview(platformRow)
        switchPlatform = platformRow.subviews.compactMap { $0 as? UISwitch }.first
        y += 52
    }

    private func addZsignAdhocOptions(at y: inout CGFloat) {
        addSectionTitle("zsign 伪签名选项", at: &y)
        // 可以添加 zsign 特有的额外开关，例如强制重签等，这里做一个示范开关
        let extraRow = makeSwitchRow("启用额外 Entitlements 合并", isOn: false) { [weak self] on in
            // 可根据需要调整 config 或生成不同的 entitlements
            if on {
                self?.config.entitlementContent = (self?.config.entitlementContent ?? "") + "\n<!-- extra flags -->"
            }
        }
        extraRow.frame = CGRect(x: pad, y: y, width: contentWidth, height: 46)
        contentView.addSubview(extraRow)
        zsignAdhocSwitch = extraRow.subviews.compactMap { $0 as? UISwitch }.first
        y += 52
    }

    private func addProvisioningTable(at y: inout CGFloat) {
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
            let pv = UITableView(frame: CGRect(x: pad, y: y, width: contentWidth, height: provTableHeight))
            pv.delegate = self
            pv.dataSource = self
            pv.backgroundColor = .clear
            pv.tag = 2
            pv.isScrollEnabled = false
            pv.register(UITableViewCell.self, forCellReuseIdentifier: "provCell")
            contentView.addSubview(pv)
            provTableView = pv
            y += provTableHeight + 8
        }
    }

    // MARK: - UI 更新辅助
    private func updateCertTable() {
        guard let tv = certTableView else { return }
        let newHeight = min(CGFloat(availableCerts.count * 44), 200)
        tv.frame.size.height = newHeight
        tv.reloadData()
    }

    private func updateProvisioningTable() {
        guard let tv = provTableView else { return }
        let newHeight = min(CGFloat(availableProvisionings.count * 44), 120)
        tv.frame.size.height = newHeight
        tv.reloadData()
    }

    // MARK: - Actions
    @objc private func engineChanged(_ sender: UISegmentedControl) {
        config.engine = sender.selectedSegmentIndex == 0 ? .ldid2 : .zsign
        config.mode = .adhoc   // 重置为伪签名模式
        buildUI()
    }

    @objc private func pseudoSwitchChanged(_ sender: UISwitch) {
        config.mode = sender.isOn ? .adhoc : .real
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
        alert.addAction(UIAlertAction(title: "📦 itunesstored（巨魔商店）", style: .default) { [weak self] _ in
            self?.installSigned(path: signedPath, method: .itunesstored)
        })
        alert.addAction(UIAlertAction(title: "⚙️ 系统直接安装", style: .default) { [weak self] _ in
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

    // MARK: - 文本字段回调
    @objc private func teamIDChanged(_ tf: UITextField) { config.teamID = tf.text ?? "" }
    @objc private func bundleIDChanged(_ tf: UITextField) { config.bundleId = tf.text?.isEmpty == true ? nil : tf.text }
    @objc private func displayNameChanged(_ tf: UITextField) { config.displayName = tf.text?.isEmpty == true ? nil : tf.text }
    @objc private func passwordChanged(_ tf: UITextField) { config.certPassword = tf.text ?? "troll" }

    @objc private func togglePasswordVisibility() {
        guard let field = passwordField else { return }
        field.isSecureTextEntry.toggle()
        let btn = field.rightView as? UIButton
        let imageName = field.isSecureTextEntry ? "eye" : "eye.slash"
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