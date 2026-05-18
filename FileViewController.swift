import UIKit
import UniformTypeIdentifiers

class FileViewController: UIViewController {

    // MARK: - Properties
    var currentPath: String = {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        return docs
    }()
    
    private var items: [String] = []
    private var filteredItems: [String] = []
    private var isSearching = false
    private var selectedFiles: Set<String> = []
    private var copySourcePath: String?
    private var cutSourcePath: String?

    // MARK: - UI Components
    private let tableView = UITableView()
    private let pathBar = UIScrollView()
    private let searchBar = UISearchBar()
    private let toolbar = UIToolbar()

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Files"
        view.backgroundColor = Theme.bg
        
        setupPathBar()
        setupSearchBar()
        setupTableView()
        setupToolbar()
        setupGestures()
        refreshFiles()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshFiles()
    }

    // MARK: - UI Setup
    private func setupPathBar() {
        pathBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 38)
        pathBar.showsHorizontalScrollIndicator = false
        pathBar.backgroundColor = UIColor(white: 0.08, alpha: 0.95)
        view.addSubview(pathBar)
    }

    private func setupSearchBar() {
        searchBar.frame = CGRect(x: 0, y: 38, width: view.bounds.width, height: 44)
        searchBar.delegate = self
        searchBar.placeholder = "Search files..."
        searchBar.barStyle = .black
        searchBar.searchTextField.backgroundColor = UIColor(white: 0.15, alpha: 1)
        searchBar.searchTextField.textColor = .white
        view.addSubview(searchBar)
    }

    private func setupTableView() {
        tableView.frame = CGRect(x: 0, y: 82, width: view.bounds.width, height: view.bounds.height - 126)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.backgroundColor = .clear
        tableView.separatorColor = Theme.separator
        tableView.keyboardDismissMode = .onDrag
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = 52
        view.addSubview(tableView)
    }

    private func setupToolbar() {
        toolbar.frame = CGRect(x: 0, y: view.bounds.height - 44, width: view.bounds.width, height: 44)
        toolbar.barTintColor = Theme.toolbar
        toolbar.tintColor = Theme.accent
        toolbar.items = [
            UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.down"), style: .plain, target: self, action: #selector(importFiles)),
            UIBarButtonItem(image: UIImage(systemName: "folder.badge.plus"), style: .plain, target: self, action: #selector(newFolder)),
            UIBarButtonItem(image: UIImage(systemName: "doc.badge.plus"), style: .plain, target: self, action: #selector(newFile)),
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), style: .plain, target: self, action: #selector(copySelected)),
            UIBarButtonItem(image: UIImage(systemName: "trash"), style: .plain, target: self, action: #selector(deleteSelected)),
            UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: self, action: #selector(shareSelected)),
        ]
        view.addSubview(toolbar)
    }

    private func setupGestures() {
        let swipeBack = UISwipeGestureRecognizer(target: self, action: #selector(goBack))
        swipeBack.direction = .right
        view.addGestureRecognizer(swipeBack)
        
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        tableView.addGestureRecognizer(longPress)
    }

    // MARK: - Data
    private var displayItems: [String] {
        isSearching ? filteredItems : items
    }

    private func refreshFiles() {
        items = listDirectory(currentPath)
        buildPathBar()
        tableView.reloadData()
        updateTitle()
    }

    private func updateTitle() {
        if currentPath == Helper.docsDir {
            title = "Files"
        } else if currentPath == Helper.certsDir {
            title = "Certificates"
        } else if currentPath == Helper.dylibsDir {
            title = "Dylibs"
        } else if currentPath == Helper.ipasDir {
            title = "IPAs"
        } else if currentPath == Helper.signedDir {
            title = "Signed"
        } else {
            title = (currentPath as NSString).lastPathComponent
        }
    }

    // MARK: - Path Bar
    private func buildPathBar() {
        pathBar.subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 10

        // Back button
        let backBtn = UIButton(type: .system)
        backBtn.setTitle("←", for: .normal)
        backBtn.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        backBtn.setTitleColor(Theme.accent, for: .normal)
        backBtn.frame = CGRect(x: x, y: 4, width: 35, height: 28)
        backBtn.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        pathBar.addSubview(backBtn)
        x += 40

        // Path components
        let displayPath = currentPath
            .replacingOccurrences(of: Helper.docsDir, with: "Documents")
            .replacingOccurrences(of: Helper.certsDir, with: "Certs")
            .replacingOccurrences(of: Helper.dylibsDir, with: "Dylibs")
            .replacingOccurrences(of: Helper.ipasDir, with: "IPAs")
            .replacingOccurrences(of: Helper.signedDir, with: "Signed")
        
        let parts = displayPath.components(separatedBy: "/").filter { !$0.isEmpty }
        for (i, part) in parts.enumerated() {
            let btn = UIButton(type: .system)
            let title = i == 0 ? part : "/\(part)"
            btn.setTitle(title, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 11)
            btn.setTitleColor(i == parts.count - 1 ? .white : Theme.accent, for: .normal)
            btn.sizeToFit()
            btn.frame = CGRect(x: x, y: 10, width: max(btn.bounds.width + 10, 35), height: 20)
            btn.addTarget(self, action: #selector(pathTapped(_:)), for: .touchUpInside)
            pathBar.addSubview(btn)
            x += btn.bounds.width + 4
        }

        // Exit button
        x += 10
        let exitBtn = UIButton(type: .system)
        exitBtn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        exitBtn.tintColor = .systemRed
        exitBtn.frame = CGRect(x: x, y: 6, width: 28, height: 28)
        exitBtn.addTarget(self, action: #selector(exitToRoot), for: .touchUpInside)
        pathBar.addSubview(exitBtn)

        pathBar.contentSize = CGSize(width: x + 40, height: 38)
    }

    // MARK: - Actions
    @objc private func goBack() {
        let parent = (currentPath as NSString).deletingLastPathComponent
        if parent != currentPath && !parent.isEmpty && parent != "/" {
            currentPath = parent
            refreshFiles()
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    @objc private func exitToRoot() {
        navigationController?.popToRootViewController(animated: true)
    }

    @objc private func pathTapped(_ sender: UIButton) {
        guard let title = sender.title(for: .normal) else { return }
        let cleanTitle = title.hasPrefix("/") ? String(title.dropFirst()) : title
        let fullPath = currentPath + "/" + cleanTitle
        if isDirectory(fullPath) {
            let vc = FileViewController()
            vc.currentPath = fullPath
            navigationController?.pushViewController(vc, animated: true)
        }
    }

    @objc private func importFiles() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    @objc private func newFolder() {
        let alert = UIAlertController(title: "New Folder", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Folder name" }
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let name = alert.textFields?.first?.text, !name.isEmpty else { return }
            self?.createDirectory(named: name, at: self?.currentPath ?? "")
            self?.refreshFiles()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func newFile() {
        let alert = UIAlertController(title: "New File", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "File name" }
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let name = alert.textFields?.first?.text, !name.isEmpty else { return }
            self?.createFile(named: name, at: self?.currentPath ?? "")
            self?.refreshFiles()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func copySelected() {
        guard let file = selectedFiles.first else { return }
        copySourcePath = currentPath + "/" + file
        cutSourcePath = nil
        Toast.show("Copied", on: view)
    }

    @objc private func deleteSelected() {
        guard !selectedFiles.isEmpty else { return }
        let alert = UIAlertController(title: "Delete \(selectedFiles.count) items?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.performDelete()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func performDelete() {
        for file in selectedFiles {
            try? FileManager.default.removeItem(atPath: currentPath + "/" + file)
        }
        selectedFiles.removeAll()
        refreshFiles()
    }

    @objc private func shareSelected() {
        guard let file = selectedFiles.first else { return }
        let path = currentPath + "/" + file
        let url = URL(fileURLWithPath: path)
        let avc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = avc.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(avc, animated: true)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point) else { return }
        let name = displayItems[indexPath.row]
        let fullPath = currentPath + "/" + name
        showContextMenu(for: name, path: fullPath)
    }

    private func showContextMenu(for name: String, path: String) {
        let alert = UIAlertController(title: name, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Copy", style: .default) { [weak self] _ in
            self?.copySourcePath = path
            self?.cutSourcePath = nil
        })
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self] _ in
            self?.showRenameAlert(for: path)
        })
        if name.hasSuffix(".ipa") {
            alert.addAction(UIAlertAction(title: "Sign this IPA", style: .default) { [weak self] _ in
                NotificationCenter.default.post(name: NSNotification.Name("OpenIPA"), object: nil, userInfo: ["path": path])
                self?.tabBarController?.selectedIndex = 1
            })
        }
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            try? FileManager.default.removeItem(atPath: path)
            self?.refreshFiles()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = alert.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(alert, animated: true)
    }

    private func showRenameAlert(for path: String) {
        let alert = UIAlertController(title: "Rename", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = (path as NSString).lastPathComponent }
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            guard let newName = alert.textFields?.first?.text, !newName.isEmpty else { return }
            let parent = (path as NSString).deletingLastPathComponent
            try? FileManager.default.moveItem(atPath: path, toPath: parent + "/" + newName)
            self?.refreshFiles()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - UITableView Delegate & DataSource
extension FileViewController: UITableViewDelegate, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        displayItems.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "c") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "c")
        let name = displayItems[indexPath.row]
        let fullPath = currentPath + "/" + name
        let isDir = isDirectory(fullPath)

        cell.textLabel?.text = name
        cell.textLabel?.textColor = .white
        cell.textLabel?.font = .systemFont(ofSize: 14)
        cell.detailTextLabel?.text = isDir ? "Folder" : fileSize(at: fullPath)
        cell.detailTextLabel?.textColor = .gray
        cell.detailTextLabel?.font = .systemFont(ofSize: 11)
        cell.imageView?.image = UIImage(systemName: isDir ? "folder.fill" : "doc.fill")
        cell.imageView?.tintColor = isDir ? .systemYellow : .systemGray
        cell.backgroundColor = .clear
        cell.accessoryType = isDir ? .disclosureIndicator : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let name = displayItems[indexPath.row]
        let fullPath = currentPath + "/" + name
        if isDirectory(fullPath) {
            let vc = FileViewController()
            vc.currentPath = fullPath
            navigationController?.pushViewController(vc, animated: true)
        } else {
            selectedFiles.insert(name)
            if name.hasSuffix(".ipa") {
                NotificationCenter.default.post(name: NSNotification.Name("OpenIPA"), object: nil, userInfo: ["path": fullPath])
                tabBarController?.selectedIndex = 1
            }
        }
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        selectedFiles.remove(displayItems[indexPath.row])
    }
}

// MARK: - UISearchBarDelegate
extension FileViewController: UISearchBarDelegate {
    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        isSearching = true
        searchBar.showsCancelButton = true
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        filteredItems = searchText.isEmpty ? items : items.filter { $0.localizedCaseInsensitiveContains(searchText) }
        tableView.reloadData()
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        isSearching = false
        searchBar.text = ""
        searchBar.showsCancelButton = false
        searchBar.resignFirstResponder()
        refreshFiles()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

// MARK: - UIDocumentPickerDelegate
extension FileViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            let destPath = currentPath + "/" + url.lastPathComponent
            try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: destPath))
            url.stopAccessingSecurityScopedResource()
        }
        refreshFiles()
    }
}

// MARK: - Helper Methods (replacing FileManagerService)
extension FileViewController {
    private func listDirectory(_ path: String) -> [String] {
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
    
    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }
    
    private func fileSize(at path: String) -> String {
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: path)
            let size = attr[.size] as? Int64 ?? 0
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        } catch {
            return ""
        }
    }
    
    private func createDirectory(named name: String, at path: String) {
        let newDir = path + "/" + name
        try? FileManager.default.createDirectory(atPath: newDir, withIntermediateDirectories: true)
    }
    
    private func createFile(named name: String, at path: String) {
        let filePath = path + "/" + name
        FileManager.default.createFile(atPath: filePath, contents: nil)
    }
}

// MARK: - Helper Extensions
extension FileViewController {
    struct Helper {
        static let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        static let certsDir = docsDir + "/Certificates"
        static let dylibsDir = docsDir + "/Dylibs"
        static let ipasDir = docsDir + "/IPAs"
        static let signedDir = docsDir + "/Signed"
    }
}
