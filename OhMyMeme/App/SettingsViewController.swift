import UIKit

final class SettingsViewController: UITableViewController {

    private enum RowKind {
        case autoPlayGif, showUncategorized, copyMode, storage, clearAll, version
    }

    private struct Section {
        let title: String?
        let rows: [(RowKind, String)]
    }

    private let config = AppContext.shared.config
    private var sections: [Section] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped)
        )
        let navBar = navigationController?.navigationBar
        navBar?.barStyle = .black
        navBar?.titleTextAttributes = [.foregroundColor: UIColor.white]
        navBar?.tintColor = UIColor(hex: 0x3B82F6)
        view.backgroundColor = UIColor(hex: 0x0D0D0F)
        tableView.backgroundColor = UIColor(hex: 0x0D0D0F)
        tableView.separatorColor = UIColor(hex: 0x27272A)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        sections = [
            Section(title: "表情显示", rows: [
                (.autoPlayGif, "动图自动播放"),
                (.showUncategorized, "显示「未分类」分组")
            ]),
            Section(title: "复制处理", rows: [
                (.copyMode, "复制处理模式")
            ]),
            Section(title: "存储", rows: [
                (.storage, "数据位置")
            ]),
            Section(title: "危险操作", rows: [
                (.clearAll, "清空本地全部数据")
            ]),
            Section(title: "关于", rows: [
                (.version, "版本")
            ])
        ]
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        if let header = view as? UITableViewHeaderFooterView {
            header.textLabel?.textColor = UIColor(hex: 0x71717A)
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.backgroundColor = UIColor(hex: 0x1E1E22)
        cell.textLabel?.textColor = .white
        cell.detailTextLabel?.textColor = UIColor(hex: 0x9CA3AF)
        cell.detailTextLabel?.numberOfLines = 2
        cell.accessoryView = nil
        cell.accessoryType = .none

        let (kind, title) = sections[indexPath.section].rows[indexPath.row]
        cell.textLabel?.text = title
        switch kind {
        case .autoPlayGif:
            cell.accessoryView = makeSwitch(value: config.bool("auto_play_gif")) { [weak self] on in
                self?.config.set("auto_play_gif", on)
                self?.config.save()
                NotificationCenter.default.post(name: .configChanged, object: nil)
            }
        case .showUncategorized:
            cell.accessoryView = makeSwitch(value: config.bool("show_uncategorized")) { [weak self] on in
                self?.config.set("show_uncategorized", on)
                self?.config.save()
                NotificationCenter.default.post(name: .configChanged, object: nil)
            }
        case .copyMode:
            cell.detailTextLabel?.text = copyModeName(config.int("copy_resize_mode"))
            cell.accessoryType = .disclosureIndicator
        case .storage:
            cell.detailTextLabel?.text = StoragePaths.dataDir.path
        case .clearAll:
            cell.textLabel?.textColor = UIColor(hex: 0xEF4444)
        case .version:
            cell.detailTextLabel?.text = versionString
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let kind = sections[indexPath.section].rows[indexPath.row].0
        switch kind {
        case .copyMode:
            showCopyModePicker()
        case .clearAll:
            confirmClearAll()
        default:
            break
        }
    }

    // MARK: - helpers

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    private func makeSwitch(value: Bool, handler: @escaping (Bool) -> Void) -> UISwitch {
        let sw = UISwitch()
        sw.isOn = value
        sw.onTintColor = UIColor(hex: 0x3B82F6)
        sw.addAction(UIAction { _ in handler(sw.isOn) }, for: .valueChanged)
        return sw
    }

    private func copyModeName(_ mode: Int) -> String {
        let names = ["不处理", "WebP 缩放", "转 GIF", "转 GIF 隐写原图"]
        guard mode >= 0, mode < names.count else { return names[0] }
        return names[mode]
    }

    private func showCopyModePicker() {
        let names = ["不处理", "WebP 缩放", "转 GIF", "转 GIF 隐写原图"]
        let current = config.int("copy_resize_mode")
        let ac = UIAlertController(title: "复制处理模式", message: nil, preferredStyle: .actionSheet)
        for (i, name) in names.enumerated() {
            ac.addAction(UIAlertAction(title: i == current ? "✓ \(name)" : name, style: .default) { [weak self] _ in
                self?.config.set("copy_resize_mode", i)
                self?.config.save()
                self?.tableView.reloadData()
            })
        }
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.popoverPresentationController?.sourceView = view
        present(ac, animated: true)
    }

    private func confirmClearAll() {
        let ac = UIAlertController(
            title: "清空本地全部数据",
            message: "将删除全部表情包、分组及相关数据，此操作不可恢复。",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.addAction(UIAlertAction(title: "继续", style: .destructive) { [weak self] _ in
            self?.confirmClearAllFinal()
        })
        present(ac, animated: true)
    }

    private func confirmClearAllFinal() {
        let ac = UIAlertController(
            title: "二次确认",
            message: "确定要清空本地全部表情包与数据吗？",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.addAction(UIAlertAction(title: "确认清空", style: .destructive) { [weak self] _ in
            self?.performClearAll()
        })
        present(ac, animated: true)
    }

    private func performClearAll() {
        AppContext.shared.queue.async {
            AppContext.shared.db.deleteAll()
            let fm = FileManager.default
            try? fm.removeItem(at: StoragePaths.cacheDir)
            try? fm.removeItem(at: StoragePaths.thumbnailDir)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .dataChanged, object: nil)
            }
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(version) (\(build))"
    }
}