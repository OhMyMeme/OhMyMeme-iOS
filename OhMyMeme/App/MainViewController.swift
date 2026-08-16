import UIKit
import PhotosUI
import UniformTypeIdentifiers

final class MainViewController: UIViewController {

    private static let memePage = 200

    // MARK: - 数据

    private struct Chip {
        let id: Int64?
        let name: String
        let hasChildren: Bool
    }

    private var chips: [Chip] = []
    private var selectedChipID: Int64?
    private var expandedParentIDs: Set<Int64> = []

    private var memes: [Meme] = []
    private var animatedByID: [Int64: Bool] = [:]
    private var hasMore = true
    private var loading = false
    private var currentKeyword = ""
    private var searchWorkItem: DispatchWorkItem?

    // MARK: - 视图

    private let searchBar = UISearchBar()
    private let chipsView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private let gridView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private let emptyLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let importButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(hex: 0x0D0D0F)
        setupViews()
        NotificationCenter.default.addObserver(self, selector: #selector(onDataChanged), name: .dataChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onConfigChanged), name: .configChanged, object: nil)
        reloadChips()
        loadMoreIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadChips()
    }

    // MARK: - 布局

    private func setupViews() {
        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        let title = UILabel()
        title.text = "表情包"
        title.textColor = .white
        title.font = .systemFont(ofSize: 19, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(title)

        importButton.setImage(UIImage(systemName: "plus"), for: .normal)
        importButton.tintColor = UIColor(hex: 0x3B82F6)
        importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)
        importButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(importButton)

        settingsButton.setImage(UIImage(systemName: "gearshape.fill"), for: .normal)
        settingsButton.tintColor = UIColor(hex: 0x9CA3AF)
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(settingsButton)

        searchBar.placeholder = "搜索表情包"
        searchBar.barStyle = .black
        searchBar.isTranslucent = true
        searchBar.searchBarStyle = .minimal
        searchBar.searchTextField.backgroundColor = UIColor(hex: 0x1E1E22)
        searchBar.searchTextField.textColor = .white
        searchBar.delegate = self
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)

        let chipLayout = UICollectionViewFlowLayout()
        chipLayout.scrollDirection = .horizontal
        chipLayout.minimumLineSpacing = 8
        chipLayout.minimumInteritemSpacing = 8
        chipsView.collectionViewLayout = chipLayout
        chipsView.backgroundColor = .clear
        chipsView.showsHorizontalScrollIndicator = false
        chipsView.contentInset = UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        chipsView.dataSource = self
        chipsView.delegate = self
        chipsView.register(ChipCell.self, forCellWithReuseIdentifier: ChipCell.reuseId)
        chipsView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chipsView)

        let gridLayout = UICollectionViewFlowLayout()
        gridLayout.minimumLineSpacing = 2
        gridLayout.minimumInteritemSpacing = 2
        gridView.collectionViewLayout = gridLayout
        gridView.backgroundColor = .clear
        gridView.alwaysBounceVertical = true
        gridView.keyboardDismissMode = .onDrag
        gridView.dragInteractionEnabled = true
        gridView.dataSource = self
        gridView.delegate = self
        gridView.dragDelegate = self
        gridView.dropDelegate = self
        gridView.register(MemeGridCell.self, forCellWithReuseIdentifier: MemeGridCell.reuseId)
        gridView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gridView)

        emptyLabel.text = "没有匹配的表情包"
        emptyLabel.textColor = UIColor(hex: 0x71717A)
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        spinner.color = UIColor(hex: 0x9CA3AF)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),

            title.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            title.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            importButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            importButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            importButton.widthAnchor.constraint(equalToConstant: 36),
            importButton.heightAnchor.constraint(equalToConstant: 36),

            settingsButton.trailingAnchor.constraint(equalTo: importButton.leadingAnchor, constant: -4),
            settingsButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 36),
            settingsButton.heightAnchor.constraint(equalToConstant: 36),

            searchBar.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            searchBar.heightAnchor.constraint(equalToConstant: 40),

            chipsView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            chipsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chipsView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chipsView.heightAnchor.constraint(equalToConstant: 42),

            gridView.topAnchor.constraint(equalTo: chipsView.bottomAnchor),
            gridView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gridView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: gridView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: gridView.centerYAnchor),

            spinner.centerXAnchor.constraint(equalTo: gridView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: gridView.centerYAnchor)
        ])
    }

    // MARK: - 数据加载

    @objc private func onDataChanged() {
        reloadChips()
        resetAndReload()
    }

    @objc private func onConfigChanged() {
        reloadChips()
        gridView.reloadData()
    }

    private func reloadChips() {
        AppContext.shared.queue.async { [weak self] in
            guard let self else { return }
            let db = AppContext.shared.db
            let expanded = self.expandedParentIDs
            var chips: [Chip] = []
            chips.append(Chip(id: nil, name: "全部 (\(db.count()))", hasChildren: false))
            chips.append(Chip(id: -2, name: "收藏 (\(db.count(favoriteOnly: true)))", hasChildren: false))
            chips.append(Chip(id: -3, name: "最近使用 (\(db.countRecent()))", hasChildren: false))
            if AppContext.shared.config.bool("show_uncategorized") {
                chips.append(Chip(id: -4, name: "未分类 (\(db.count(uncategorizedOnly: true)))", hasChildren: false))
            }
            let roots = db.getCollections().filter { $0.parentId == nil }
            for c in roots {
                let children = db.getChildCollections(c.id)
                chips.append(Chip(
                    id: c.id,
                    name: c.name + (children.isEmpty ? "" : " ▸"),
                    hasChildren: !children.isEmpty
                ))
                if expanded.contains(c.id) {
                    for child in children {
                        chips.append(Chip(id: child.id, name: child.name, hasChildren: false))
                    }
                }
            }
            let snapshot = chips
            DispatchQueue.main.async {
                self.chips = snapshot
                self.chipsView.reloadData()
            }
        }
    }

    private func resetAndReload() {
        memes = []
        animatedByID = [:]
        hasMore = true
        loading = false
        gridView.reloadData()
        updateEmptyState()
        loadMoreIfNeeded()
    }

    private func loadMoreIfNeeded() {
        guard !loading, hasMore else { return }
        loading = true
        let keyword = currentKeyword
        let sid = selectedChipID
        let offset = memes.count
        let isRecent = sid == -3
        let isFav = sid == -2
        let isUncat = sid == -4
        let cid = (sid ?? 0) > 0 ? sid : nil

        AppContext.shared.queue.async { [weak self] in
            guard let self else { return }
            let db = AppContext.shared.db
            var page: [Meme] = []
            var total = 0
            if isRecent {
                page = db.getRecent(limit: Self.memePage, offset: offset)
                total = db.countRecent()
            } else {
                page = db.search(
                    keyword: keyword,
                    collectionId: cid,
                    favoriteOnly: isFav,
                    uncategorizedOnly: isUncat,
                    offset: offset,
                    limit: Self.memePage
                )
                total = db.count(keyword: keyword, collectionId: cid, favoriteOnly: isFav, uncategorizedOnly: isUncat)
            }
            var animated: [Int64: Bool] = [:]
            for meme in page {
                animated[meme.id] = FileUtils.isAnimated(url: Thumbnailer.cacheFileURL(meme.filename))
            }
            DispatchQueue.main.async {
                self.animatedByID.merge(animated) { _, new in new }
                self.memes.append(contentsOf: page)
                self.hasMore = self.memes.count < total
                self.loading = false
                self.gridView.reloadData()
                self.updateEmptyState()
            }
        }
    }

    private func updateEmptyState() {
        if memes.isEmpty && !loading {
            emptyLabel.isHidden = false
            spinner.stopAnimating()
        } else if memes.isEmpty {
            emptyLabel.isHidden = true
            spinner.startAnimating()
        } else {
            emptyLabel.isHidden = true
            spinner.stopAnimating()
        }
    }

    // MARK: - 排序

    private func canReorder() -> Bool {
        currentKeyword.isEmpty && (selectedChipID ?? 0) >= 0 && memes.count >= 2
    }

    private func persistOrder(_ ids: [Int64]) {
        let db = AppContext.shared.db
        if let cid = (selectedChipID ?? 0) > 0 ? selectedChipID : nil {
            AppContext.shared.queue.async { db.reorderCollectionMembers(cid, ids) }
        } else {
            AppContext.shared.queue.async { db.reorderMemes(ids) }
        }
    }

    // MARK: - 交互

    private func chipTapped(_ chip: Chip) {
        guard let id = chip.id else {
            selectedChipID = nil
            chipsView.reloadData()
            resetAndReload()
            return
        }
        if chip.hasChildren {
            if expandedParentIDs.contains(id) {
                expandedParentIDs.remove(id)
            } else {
                expandedParentIDs.insert(id)
                selectedChipID = id
            }
        } else {
            selectedChipID = id
        }
        chipsView.reloadData()
        reloadChips()
        resetAndReload()
    }

    private func share(meme: Meme) {
        AppContext.shared.queue.async { [weak self] in
            AppContext.shared.db.recordUse(meme.id)
            let processed = MemeCopyProcessor.process(meme: meme)
            DispatchQueue.main.async {
                guard let self else { return }
                let url = processed?.url ?? Thumbnailer.findMemeFile(meme.filename)
                guard let url else {
                    self.toast("文件缺失")
                    return
                }
                let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                av.popoverPresentationController?.sourceView = self.view
                av.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                self.present(av, animated: true)
            }
        }
    }

    private func showMenu(for meme: Meme) {
        AppContext.shared.queue.async { [weak self] in
            guard let self else { return }
            let isFav = AppContext.shared.db.isFavorite(meme.id)
            DispatchQueue.main.async {
                let ac = UIAlertController(title: meme.displayName, message: nil, preferredStyle: .actionSheet)
                ac.addAction(UIAlertAction(title: "分享", style: .default) { [weak self] _ in
                    self?.share(meme: meme)
                })
                ac.addAction(UIAlertAction(title: isFav ? "取消收藏" : "收藏", style: .default) { [weak self] _ in
                    self?.toggleFavorite(meme)
                })
                ac.addAction(UIAlertAction(title: "重命名", style: .default) { [weak self] _ in
                    self?.promptRename(meme)
                })
                ac.addAction(UIAlertAction(title: "加入分组", style: .default) { [weak self] _ in
                    self?.presentAddToCollection(meme)
                })
                if (self.selectedChipID ?? 0) > 0 {
                    ac.addAction(UIAlertAction(title: "从当前分组移除", style: .default) { [weak self] _ in
                        self?.removeFromCurrentCollection(meme)
                    })
                }
                ac.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
                    self?.confirmDelete(meme)
                })
                ac.addAction(UIAlertAction(title: "取消", style: .cancel))
                ac.popoverPresentationController?.sourceView = self.view
                self.present(ac, animated: true)
            }
        }
    }

    private func toggleFavorite(_ meme: Meme) {
        AppContext.shared.queue.async { [weak self] in
            let fav = AppContext.shared.db.toggleFavorite(meme.id)
            DispatchQueue.main.async {
                self?.toast(fav ? "已收藏" : "已取消收藏")
                NotificationCenter.default.post(name: .dataChanged, object: nil)
            }
        }
    }

    private func promptRename(_ meme: Meme) {
        let ac = UIAlertController(title: "重命名", message: nil, preferredStyle: .alert)
        ac.addTextField { $0.text = meme.originalName }
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.addAction(UIAlertAction(title: "确定", style: .default) { [weak self, weak ac] _ in
            let text = ac?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            AppContext.shared.queue.async {
                AppContext.shared.db.updateMeme(meme.id, updates: ["original_name": text])
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .dataChanged, object: nil)
                }
            }
        })
        present(ac, animated: true)
    }

    private func presentAddToCollection(_ meme: Meme) {
        AppContext.shared.queue.async { [weak self] in
            guard let self else { return }
            let roots = AppContext.shared.db.getCollections().filter { $0.parentId == nil }
            DispatchQueue.main.async {
                let ac = UIAlertController(title: "加入分组", message: nil, preferredStyle: .actionSheet)
                for c in roots {
                    ac.addAction(UIAlertAction(title: c.name, style: .default) { [weak self] _ in
                        self?.addToCollection(meme, c.id)
                    })
                }
                ac.addAction(UIAlertAction(title: "新建分组…", style: .default) { [weak self] _ in
                    self?.promptCreateCollectionAndAdd(meme)
                })
                ac.addAction(UIAlertAction(title: "取消", style: .cancel))
                ac.popoverPresentationController?.sourceView = self.view
                self.present(ac, animated: true)
            }
        }
    }

    private func addToCollection(_ meme: Meme, _ cid: Int64) {
        AppContext.shared.queue.async {
            AppContext.shared.db.addToCollection(meme.id, cid)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .dataChanged, object: nil)
            }
        }
    }

    private func promptCreateCollectionAndAdd(_ meme: Meme) {
        let ac = UIAlertController(title: "新建分组", message: nil, preferredStyle: .alert)
        ac.addTextField { $0.placeholder = "分组名称" }
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.addAction(UIAlertAction(title: "创建", style: .default) { [weak self, weak ac] _ in
            let name = ac?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return }
            AppContext.shared.queue.async {
                let cid = AppContext.shared.db.createCollection(name: name)
                AppContext.shared.db.addToCollection(meme.id, cid)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .dataChanged, object: nil)
                }
            }
        })
        present(ac, animated: true)
    }

    private func removeFromCurrentCollection(_ meme: Meme) {
        guard let cid = (selectedChipID ?? 0) > 0 ? selectedChipID : nil else { return }
        AppContext.shared.queue.async { [weak self] in
            AppContext.shared.db.removeFromCollection(meme.id, cid)
            DispatchQueue.main.async {
                self?.removeMemeLocally(meme.id)
                NotificationCenter.default.post(name: .dataChanged, object: nil)
            }
        }
    }

    private func confirmDelete(_ meme: Meme) {
        let ac = UIAlertController(
            title: "删除表情包",
            message: "确定删除「\(meme.displayName)」？此操作不可恢复。",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.performDelete(meme)
        })
        present(ac, animated: true)
    }

    private func performDelete(_ meme: Meme) {
        AppContext.shared.queue.async { [weak self] in
            AppContext.shared.db.deleteMeme(meme.id)
            if let f = Thumbnailer.findMemeFile(meme.filename) {
                try? FileManager.default.removeItem(at: f)
            }
            try? FileManager.default.removeItem(at: Thumbnailer.thumbnailURL(for: meme.id))
            DispatchQueue.main.async {
                self?.removeMemeLocally(meme.id)
                NotificationCenter.default.post(name: .dataChanged, object: nil)
            }
        }
    }

    private func removeMemeLocally(_ memeId: Int64) {
        guard let idx = memes.firstIndex(where: { $0.id == memeId }) else { return }
        memes.remove(at: idx)
        gridView.performBatchUpdates {
            gridView.deleteItems(at: [IndexPath(item: idx, section: 0)])
        } completion: { [weak self] _ in
            self?.updateEmptyState()
        }
    }

    // MARK: - 导入 / 设置

    @objc private func importTapped() {
        let ac = UIAlertController(title: "导入表情包", message: nil, preferredStyle: .actionSheet)
        ac.addAction(UIAlertAction(title: "从相册导入", style: .default) { [weak self] _ in
            var config = PHPickerConfiguration()
            config.filter = .images
            config.selectionLimit = 0
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            self?.present(picker, animated: true)
        })
        ac.addAction(UIAlertAction(title: "从文件导入", style: .default) { [weak self] _ in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
            picker.delegate = self
            self?.present(picker, animated: true)
        })
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.popoverPresentationController?.sourceView = importButton
        present(ac, animated: true)
    }

    private func finishImport(success: Int) {
        if success > 0 {
            toast("导入成功 \(success) 张")
            NotificationCenter.default.post(name: .dataChanged, object: nil)
        } else {
            toast("没有新表情包可导入（已存在或格式不支持）")
        }
    }

    @objc private func settingsTapped() {
        let nav = UINavigationController(rootViewController: SettingsViewController())
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    // MARK: - toast

    private var toastLabel: UILabel?

    private func toast(_ text: String) {
        toastLabel?.removeFromSuperview()
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 13)
        label.textAlignment = .center
        label.backgroundColor = UIColor(hex: 0x27272A).withAlphaComponent(0.95)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -60)
        ])
        toastLabel = label
        UIView.animate(withDuration: 0.25, animations: {
            label.alpha = 1
        }, completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 1.6, options: [], animations: {
                label.alpha = 0
            }, completion: { _ in
                label.removeFromSuperview()
                if self.toastLabel === label { self.toastLabel = nil }
            })
        })
    }
}

// MARK: - UICollectionViewDataSource / Delegate

extension MainViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        collectionView == chipsView ? chips.count : memes.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if collectionView == chipsView {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ChipCell.reuseId, for: indexPath) as! ChipCell
            let chip = chips[indexPath.item]
            cell.text = chip.name
            cell.isSelected = (chip.id == selectedChipID) || (chip.id == nil && selectedChipID == nil)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MemeGridCell.reuseId, for: indexPath) as! MemeGridCell
        let meme = memes[indexPath.item]
        cell.configure(
            meme: meme,
            isAnimated: animatedByID[meme.id] ?? false,
            autoPlay: AppContext.shared.config.bool("auto_play_gif")
        )
        cell.menuHandler = { [weak self] in
            self?.showMenu(for: meme)
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        if collectionView == chipsView {
            let chip = chips[indexPath.item]
            let width = (chip.name as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 13)]).width
            return CGSize(width: width + 28, height: 30)
        }
        let spacing: CGFloat = 2
        let cols: CGFloat = 3
        let w = floor((collectionView.bounds.width - spacing * (cols - 1)) / cols)
        return CGSize(width: w, height: w + 22)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView == chipsView {
            chipTapped(chips[indexPath.item])
        } else {
            share(meme: memes[indexPath.item])
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView == gridView else { return }
        let offsetY = scrollView.contentOffset.y + scrollView.bounds.height
        if offsetY > scrollView.contentSize.height - 400 {
            loadMoreIfNeeded()
        }
    }
}

// MARK: - UISearchBarDelegate

extension MainViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        searchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.currentKeyword = searchText
            self?.resetAndReload()
        }
        searchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

// MARK: - 拖拽重排

extension MainViewController: UICollectionViewDragDelegate, UICollectionViewDropDelegate {

    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard collectionView == gridView, indexPath.item < memes.count else { return [] }
        let meme = memes[indexPath.item]
        let provider = NSItemProvider()
        registerMemeContent(provider, for: meme)
        let item = UIDragItem(itemProvider: provider)
        item.localObject = meme
        item.previewProvider = { [weak self] in
            self?.dragPreview(for: meme, at: indexPath) ?? UIDragPreview(view: UIImageView(frame: CGRect(x: 0, y: 0, width: 120, height: 120)))
        }
        AppContext.shared.queue.async { AppContext.shared.db.recordUse(meme.id) }
        return [item]
    }

    /// 注册拖拽内容：真实图片文件（处理结果或原图），让外部聊天应用能直接发送
    private func registerMemeContent(_ provider: NSItemProvider, for meme: Meme) {
        let ext = FileUtils.ext(fromName: meme.filename)
        let concreteType: UTType? = {
            switch ext {
            case ".png": return .png
            case ".jpg", ".jpeg": return .jpeg
            case ".gif": return .gif
            case ".webp": return .webP
            case ".bmp": return .bmp
            default: return nil
            }
        }()
        let types = concreteType.map { [$0, UTType.image] } ?? [UTType.image]
        for type in types {
            provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { [weak self] completion in
                guard let self else {
                    completion(nil, NSError(domain: "OhMyMeme", code: -1, userInfo: [NSLocalizedDescriptionKey: "控制器已释放"]))
                    return nil
                }
                self.loadMemeFileData(for: meme) { data, error in
                    completion(data, error)
                }
                return nil
            }
        }
    }

    /// 后台读取原始表情文件数据（拖拽直发原图；copy_resize_mode 仅用于复制/分享，避免类型与字节不一致）
    private func loadMemeFileData(for meme: Meme, completion: @escaping (Data?, Error?) -> Void) {
        AppContext.shared.queue.async { [weak self] in
            guard let self else {
                completion(nil, NSError(domain: "OhMyMeme", code: -1, userInfo: [NSLocalizedDescriptionKey: "控制器已释放"]))
                return
            }
            guard let url = Thumbnailer.findMemeFile(meme.filename),
                  let data = try? Data(contentsOf: url)
            else {
                completion(nil, NSError(domain: "OhMyMeme", code: -1, userInfo: [NSLocalizedDescriptionKey: "文件缺失"]))
                return
            }
            completion(data, nil)
        }
    }

    /// 拖拽悬浮预览：优先取单元格当前图片，回退到缩略图文件
    private func dragPreview(for meme: Meme, at indexPath: IndexPath) -> UIDragPreview {
        let v = UIImageView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.layer.cornerRadius = 8
        if let cell = gridView.cellForItem(at: indexPath) as? MemeGridCell {
            v.image = cell.currentImage
        }
        if v.image == nil {
            let thumb = Thumbnailer.thumbnailURL(for: meme.id)
            if FileManager.default.fileExists(atPath: thumb.path) {
                v.image = UIImage(contentsOfFile: thumb.path)
            }
        }
        return UIDragPreview(view: v)
    }

    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        collectionView == gridView && canReorder()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard collectionView == gridView, canReorder() else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        performDropWith coordinator: UICollectionViewDropCoordinator
    ) {
        guard canReorder(),
              let item = coordinator.items.first,
              let src = item.sourceIndexPath
        else { return }

        let destination = coordinator.destinationIndexPath
            ?? IndexPath(item: memes.count - 1, section: 0)

        collectionView.performBatchUpdates {
            let meme = memes.remove(at: src.item)
            let insertAt = destination.item <= memes.count ? destination.item : memes.count
            memes.insert(meme, at: insertAt)
            collectionView.moveItem(at: src, to: IndexPath(item: insertAt, section: 0))
        } completion: { [weak self] _ in
            guard let self else { return }
            self.persistOrder(self.memes.map { $0.id })
        }

        let animator = coordinator.drop(item.dragItem, toItemAt: destination)
        animator.addAnimations { [weak self] in
            self?.gridView.reloadItems(at: [destination])
        }
    }
}

// MARK: - 相册 / 文件导入

extension MainViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        var remaining = results.count
        var success = 0
        for result in results {
            let provider = result.itemProvider
            let suggested = provider.suggestedName ?? ""
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
                if let data {
                    let ok = MemeImporter.importData(data, originalName: suggested)
                    if ok { success += 1 }
                }
                remaining -= 1
                if remaining == 0 {
                    DispatchQueue.main.async {
                        self?.finishImport(success: success)
                    }
                }
            }
        }
    }
}

extension MainViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else { return }
        var remaining = urls.count
        var success = 0
        for url in urls {
            AppContext.shared.queue.async { [weak self] in
                let ok = MemeImporter.importFile(at: url, originalName: url.lastPathComponent)
                DispatchQueue.main.async {
                    if ok { success += 1 }
                    remaining -= 1
                    if remaining == 0 {
                        self?.finishImport(success: success)
                    }
                }
            }
        }
    }
}