import Foundation

/// SQLite 封装，7 表 schema 与桌面端 database.py 逐列一致
final class MemeDb {
    private let db: SQLiteDatabase
    private let lock = NSLock()

    struct Collection {
        let id: Int64
        let name: String
        let parentId: Int64?
        let sortOrder: Int
    }

    init(path: String) {
        db = SQLiteDatabase(path: path)
        initSchema()
    }

    // MARK: - schema

    private func initSchema() {
        db.execute("""
            CREATE TABLE IF NOT EXISTS memes (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                filename    TEXT    NOT NULL,
                file_hash   TEXT    NOT NULL DEFAULT '',
                original_name TEXT  NOT NULL DEFAULT '',
                width       INTEGER DEFAULT 0,
                height      INTEGER DEFAULT 0,
                file_size   INTEGER DEFAULT 0,
                mime_type   TEXT    DEFAULT 'image/png',
                sort_order  INTEGER DEFAULT 0,
                stego_of_hash TEXT DEFAULT NULL,
                from_stego  INTEGER DEFAULT 0,
                created_at  TEXT    NOT NULL DEFAULT (datetime('now','localtime')),
                updated_at  TEXT    NOT NULL DEFAULT (datetime('now','localtime'))
            )
        """)
        db.execute("""
            CREATE TABLE IF NOT EXISTS tags (
                id   INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT    NOT NULL UNIQUE COLLATE NOCASE
            )
        """)
        db.execute("""
            CREATE TABLE IF NOT EXISTS meme_tags (
                meme_id INTEGER NOT NULL REFERENCES memes(id) ON DELETE CASCADE,
                tag_id  INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                PRIMARY KEY (meme_id, tag_id)
            )
        """)
        db.execute("""
            CREATE TABLE IF NOT EXISTS collections (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                name        TEXT    NOT NULL COLLATE NOCASE,
                parent_id   INTEGER DEFAULT NULL REFERENCES collections(id) ON DELETE CASCADE,
                sort_order  INTEGER DEFAULT 0
            )
        """)
        db.execute("""
            CREATE TABLE IF NOT EXISTS meme_collections (
                meme_id       INTEGER NOT NULL REFERENCES memes(id) ON DELETE CASCADE,
                collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                sort_order    INTEGER DEFAULT 0,
                PRIMARY KEY (meme_id, collection_id)
            )
        """)
        db.execute("""
            CREATE TABLE IF NOT EXISTS favorites (
                meme_id   INTEGER PRIMARY KEY REFERENCES memes(id) ON DELETE CASCADE,
                added_at  TEXT NOT NULL DEFAULT (datetime('now','localtime'))
            )
        """)
        db.execute("""
            CREATE TABLE IF NOT EXISTS recent_uses (
                meme_id   INTEGER NOT NULL REFERENCES memes(id) ON DELETE CASCADE,
                used_at   TEXT NOT NULL DEFAULT (datetime('now','localtime')),
                PRIMARY KEY (meme_id)
            )
        """)
        db.execute("CREATE INDEX IF NOT EXISTS idx_memes_hash ON memes(file_hash)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_memes_name ON memes(filename)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_recent_uses_at ON recent_uses(used_at)")
        migrateColumns()
        // 该索引依赖迁移新增的 stego_of_hash 列，必须放在迁移之后建
        db.execute("CREATE INDEX IF NOT EXISTS idx_memes_stego ON memes(stego_of_hash)")
    }

    private func migrateColumns() {
        let migrations: [(String, String, String)] = [
            ("memes", "sort_order", "INTEGER DEFAULT 0"),
            ("memes", "stego_of_hash", "TEXT DEFAULT NULL"),
            ("memes", "from_stego", "INTEGER DEFAULT 0"),
            ("collections", "parent_id", "INTEGER DEFAULT NULL REFERENCES collections(id) ON DELETE CASCADE"),
            ("collections", "sort_order", "INTEGER DEFAULT 0"),
            ("meme_collections", "sort_order", "INTEGER DEFAULT 0")
        ]
        for (table, column, definition) in migrations {
            let cols = db.query("PRAGMA table_info(\(table))").compactMap { $0["name"] as? String }
            if !cols.contains(column) {
                db.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
            }
        }
    }

    // MARK: - 增删改

    func addMeme(
        filename: String,
        fileHash: String = "",
        width: Int = 0,
        height: Int = 0,
        fileSize: Int64 = 0,
        mimeType: String = "image/png",
        originalName: String = "",
        tags: [String]? = nil,
        stegoOfHash: String? = nil,
        fromStego: Int = 0
    ) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        db.execute(
            """
            INSERT INTO memes (filename, file_hash, width, height, file_size, mime_type,
                               original_name, stego_of_hash, from_stego)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [filename, fileHash, width, height, fileSize, mimeType, originalName, stegoOfHash, fromStego]
        )
        let memeId = db.lastInsertRowId()
        if let tags, !tags.isEmpty {
            setMemeTagsUnlocked(memeId, tags)
        }
        return memeId
    }

    func deleteMeme(_ memeId: Int64) {
        lock.lock(); defer { lock.unlock() }
        db.execute("DELETE FROM memes WHERE id=?", [memeId])
        pruneOrphanTags()
    }

    func updateMeme(_ memeId: Int64, updates: [String: Any]) {
        let allowed = Set([
            "filename", "file_hash", "width", "height", "file_size",
            "mime_type", "original_name", "stego_of_hash", "from_stego"
        ])
        var sets: [String] = []
        var vals: [Any?] = []
        for (k, v) in updates where allowed.contains(k) {
            sets.append("\(k)=?")
            vals.append(v)
        }
        guard !sets.isEmpty else { return }
        sets.append("updated_at=datetime('now','localtime')")
        lock.lock(); defer { lock.unlock() }
        db.execute("UPDATE memes SET \(sets.joined(separator: ", ")) WHERE id=?", vals + [memeId])
    }

    // MARK: - 标签

    private func pruneOrphanTags() {
        db.execute("DELETE FROM tags WHERE id NOT IN (SELECT DISTINCT tag_id FROM meme_tags)")
    }

    private func setMemeTagsUnlocked(_ memeId: Int64, _ tags: [String]) {
        db.execute("DELETE FROM meme_tags WHERE meme_id=?", [memeId])
        for raw in tags {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if tag.isEmpty { continue }
            db.execute("INSERT OR IGNORE INTO tags (name) VALUES (?)", [tag])
            if let row = db.query("SELECT id FROM tags WHERE name=?", [tag]).first,
               let tagId = row["id"] as? Int {
                db.execute(
                    "INSERT OR IGNORE INTO meme_tags (meme_id, tag_id) VALUES (?, ?)",
                    [memeId, Int64(tagId)]
                )
            }
        }
        pruneOrphanTags()
    }

    func setMemeTags(_ memeId: Int64, _ tags: [String]) {
        lock.lock(); defer { lock.unlock() }
        setMemeTagsUnlocked(memeId, tags)
    }

    func getMemeTags(_ memeId: Int64) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return db.query(
            """
            SELECT t.name FROM tags t
            JOIN meme_tags mt ON mt.tag_id = t.id
            WHERE mt.meme_id = ?
            """, [memeId]
        ).compactMap { $0["name"] as? String }
    }

    func getAllTags() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return db.query("SELECT name FROM tags ORDER BY name").compactMap { $0["name"] as? String }
    }

    // MARK: - 收藏

    func toggleFavorite(_ memeId: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let exists = db.scalarInt("SELECT 1 FROM favorites WHERE meme_id=?", [memeId]) > 0
        if exists {
            db.execute("DELETE FROM favorites WHERE meme_id=?", [memeId])
            return false
        } else {
            db.execute("INSERT OR IGNORE INTO favorites (meme_id) VALUES (?)", [memeId])
            return true
        }
    }

    func isFavorite(_ memeId: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return db.scalarInt("SELECT 1 FROM favorites WHERE meme_id=?", [memeId]) > 0
    }

    // MARK: - 分组

    func createCollection(name: String, parentId: Int64? = nil) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        if let parentId {
            db.execute("INSERT OR IGNORE INTO collections (name, parent_id) VALUES (?, ?)", [name, parentId])
        } else {
            db.execute("INSERT OR IGNORE INTO collections (name) VALUES (?)", [name])
        }
        if let row = db.query("SELECT id FROM collections WHERE name=?", [name]).first {
            return (row["id"] as? Int).map(Int64.init) ?? -1
        }
        return -1
    }

    func addToCollection(_ memeId: Int64, _ collectionId: Int64) {
        lock.lock(); defer { lock.unlock() }
        db.execute(
            "INSERT OR IGNORE INTO meme_collections (meme_id, collection_id) VALUES (?, ?)",
            [memeId, collectionId]
        )
    }

    func collectionExists(name: String, parentId: Int64?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let parentId {
            return db.scalarInt(
                "SELECT 1 FROM collections WHERE name=? AND parent_id=?",
                [name, parentId]
            ) > 0
        }
        return db.scalarInt(
            "SELECT 1 FROM collections WHERE name=? AND parent_id IS NULL",
            [name]
        ) > 0
    }

    func removeFromCollection(_ memeId: Int64, _ collectionId: Int64) {
        lock.lock(); defer { lock.unlock() }
        db.execute(
            "DELETE FROM meme_collections WHERE meme_id=? AND collection_id=?",
            [memeId, collectionId]
        )
    }

    func setCollectionMembers(_ collectionId: Int64, _ memeIds: [Int64]) {
        lock.lock(); defer { lock.unlock() }
        db.execute("DELETE FROM meme_collections WHERE collection_id=?", [collectionId])
        for (i, mid) in memeIds.enumerated() {
            db.execute(
                "INSERT OR IGNORE INTO meme_collections (meme_id, collection_id, sort_order) VALUES (?, ?, ?)",
                [mid, collectionId, i]
            )
        }
    }

    func getCollections() -> [Collection] {
        lock.lock(); defer { lock.unlock() }
        return db.query(
            "SELECT id, name, parent_id, sort_order FROM collections ORDER BY sort_order ASC, name"
        ).map { row in
            Collection(
                id: (row["id"] as? Int).map(Int64.init) ?? 0,
                name: (row["name"] as? String) ?? "",
                parentId: (row["parent_id"] as? Int).map(Int64.init),
                sortOrder: (row["sort_order"] as? Int) ?? 0
            )
        }
    }

    func getChildCollections(_ parentId: Int64) -> [Collection] {
        lock.lock(); defer { lock.unlock() }
        return db.query(
            "SELECT id, name, parent_id, sort_order FROM collections WHERE parent_id=? ORDER BY sort_order ASC, name",
            [parentId]
        ).map { row in
            Collection(
                id: (row["id"] as? Int).map(Int64.init) ?? 0,
                name: (row["name"] as? String) ?? "",
                parentId: parentId,
                sortOrder: (row["sort_order"] as? Int) ?? 0
            )
        }
    }

    func getCollectionDepth(_ cid: Int64) -> Int {
        lock.lock(); defer { lock.unlock() }
        var depth = 0
        var cur = cid
        while true {
            guard let row = db.query("SELECT parent_id FROM collections WHERE id=?", [cur]).first,
                  let pid = row["parent_id"] as? Int,
                  pid != 0
            else { break }
            cur = Int64(pid)
            depth += 1
        }
        return depth
    }

    func deleteCollection(_ collectionId: Int64) {
        lock.lock(); defer { lock.unlock() }
        db.execute("DELETE FROM meme_collections WHERE collection_id=?", [collectionId])
        db.execute("DELETE FROM collections WHERE id=?", [collectionId])
    }

    func renameCollection(_ collectionId: Int64, _ newName: String) {
        lock.lock(); defer { lock.unlock() }
        db.execute("UPDATE collections SET name=? WHERE id=?", [newName, collectionId])
    }

    func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        db.execute("DELETE FROM favorites")
        db.execute("DELETE FROM meme_collections")
        db.execute("DELETE FROM meme_tags")
        db.execute("DELETE FROM memes")
        db.execute("DELETE FROM collections")
        db.execute("DELETE FROM tags")
    }

    // MARK: - 搜索

    func search(
        keyword: String = "",
        tags: [String]? = nil,
        collectionId: Int64? = nil,
        favoriteOnly: Bool = false,
        uncategorizedOnly: Bool = false,
        offset: Int = 0,
        limit: Int = 100
    ) -> [Meme] {
        lock.lock(); defer { lock.unlock() }
        var whereClauses = ["(m.stego_of_hash IS NULL OR m.stego_of_hash = '')"]
        var params: [Any?] = []

        if !keyword.isEmpty {
            whereClauses.append("(m.filename LIKE ? OR m.original_name LIKE ?)")
            let kw = "%\(keyword)%"
            params.append(kw)
            params.append(kw)
        }

        if let tags, !tags.isEmpty {
            let placeholders = tags.map { _ in "?" }.joined(separator: ",")
            whereClauses.append("""
                m.id IN (
                    SELECT mt.meme_id FROM meme_tags mt
                    JOIN tags t ON t.id = mt.tag_id
                    WHERE t.name IN (\(placeholders))
                    GROUP BY mt.meme_id HAVING COUNT(DISTINCT t.id) = ?
                )
            """)
            params.append(contentsOf: tags)
            params.append(tags.count)
        }

        if let collectionId {
            whereClauses.append("""
                m.id IN (
                    SELECT mc.meme_id FROM meme_collections mc WHERE mc.collection_id = ?
                )
            """)
            params.append(collectionId)
        }

        if favoriteOnly {
            whereClauses.append("m.id IN (SELECT meme_id FROM favorites)")
        }

        if uncategorizedOnly {
            whereClauses.append("NOT EXISTS (SELECT 1 FROM meme_collections mc WHERE mc.meme_id = m.id)")
        }

        var sql = "SELECT m.* FROM memes m WHERE \(whereClauses.joined(separator: " AND "))"
        if let collectionId {
            sql += """
                 ORDER BY (
                     SELECT mc.sort_order FROM meme_collections mc
                     WHERE mc.meme_id = m.id AND mc.collection_id = ?
                 ) ASC, m.updated_at DESC
                """
            params.append(collectionId)
        } else {
            sql += " ORDER BY m.sort_order ASC, m.updated_at DESC"
        }
        sql += " LIMIT ? OFFSET ?"
        params.append(limit)
        params.append(offset)

        return db.query(sql, params).map(Meme.init(row:))
    }

    func count(
        keyword: String = "",
        collectionId: Int64? = nil,
        favoriteOnly: Bool = false,
        uncategorizedOnly: Bool = false
    ) -> Int {
        lock.lock(); defer { lock.unlock() }
        var whereClauses = ["(stego_of_hash IS NULL OR stego_of_hash = '')"]
        var params: [Any?] = []
        if !keyword.isEmpty {
            whereClauses.append("(filename LIKE ? OR original_name LIKE ?)")
            let kw = "%\(keyword)%"
            params.append(kw)
            params.append(kw)
        }
        if let collectionId {
            whereClauses.append("id IN (SELECT meme_id FROM meme_collections WHERE collection_id = ?)")
            params.append(collectionId)
        }
        if favoriteOnly {
            whereClauses.append("id IN (SELECT meme_id FROM favorites)")
        }
        if uncategorizedOnly {
            whereClauses.append("NOT EXISTS (SELECT 1 FROM meme_collections mc WHERE mc.meme_id = id)")
        }
        let sql = "SELECT COUNT(*) FROM memes WHERE \(whereClauses.joined(separator: " AND "))"
        return db.scalarInt(sql, params)
    }

    // MARK: - 查询

    func getByHash(_ fileHash: String) -> Meme? {
        lock.lock(); defer { lock.unlock() }
        return db.query("SELECT * FROM memes WHERE file_hash=? LIMIT 1", [fileHash]).first.map(Meme.init(row:))
    }

    func getById(_ memeId: Int64) -> Meme? {
        lock.lock(); defer { lock.unlock() }
        return db.query("SELECT * FROM memes WHERE id=?", [memeId]).first.map(Meme.init(row:))
    }

    func getByFilename(_ filename: String) -> Meme? {
        lock.lock(); defer { lock.unlock() }
        return db.query("SELECT * FROM memes WHERE filename=? LIMIT 1", [filename]).first.map(Meme.init(row:))
    }

    func getAll(offset: Int = 0, limit: Int = 100) -> [Meme] {
        lock.lock(); defer { lock.unlock() }
        return db.query(
            "SELECT * FROM memes ORDER BY sort_order ASC, updated_at DESC LIMIT ? OFFSET ?",
            [limit, offset]
        ).map(Meme.init(row:))
    }

    func getRecent(limit: Int = 50, offset: Int = 0) -> [Meme] {
        lock.lock(); defer { lock.unlock() }
        return db.query(
            """
            SELECT m.* FROM memes m
            JOIN recent_uses r ON r.meme_id = m.id
            WHERE (m.stego_of_hash IS NULL OR m.stego_of_hash = '')
            ORDER BY r.used_at DESC, r.meme_id DESC LIMIT ? OFFSET ?
            """, [limit, offset]
        ).map(Meme.init(row:))
    }

    func countRecent() -> Int {
        lock.lock(); defer { lock.unlock() }
        return db.scalarInt("""
            SELECT COUNT(*) FROM memes m
            JOIN recent_uses r ON r.meme_id = m.id
            WHERE (m.stego_of_hash IS NULL OR m.stego_of_hash = '')
        """)
    }

    // MARK: - 最近使用

    func recordUse(_ memeId: Int64) {
        lock.lock(); defer { lock.unlock() }
        db.execute(
            "INSERT OR REPLACE INTO recent_uses (meme_id, used_at) VALUES (?, datetime('now','localtime'))",
            [memeId]
        )
    }

    func removeFromRecent(_ memeId: Int64) {
        lock.lock(); defer { lock.unlock() }
        db.execute("DELETE FROM recent_uses WHERE meme_id=?", [memeId])
    }

    func clearRecent() {
        lock.lock(); defer { lock.unlock() }
        db.execute("DELETE FROM recent_uses")
    }

    // MARK: - 排序

    func reorderMemes(_ memeIds: [Int64]) {
        lock.lock(); defer { lock.unlock() }
        db.transaction {
            for (i, mid) in memeIds.enumerated() {
                db.execute("UPDATE memes SET sort_order=? WHERE id=?", [i, mid])
            }
        }
    }

    func reorderCollections(_ collectionIds: [Int64]) {
        lock.lock(); defer { lock.unlock() }
        db.transaction {
            for (i, cid) in collectionIds.enumerated() {
                db.execute("UPDATE collections SET sort_order=? WHERE id=?", [i, cid])
            }
        }
    }

    func reorderCollectionMembers(_ collectionId: Int64, _ memeIds: [Int64]) {
        lock.lock(); defer { lock.unlock() }
        db.transaction {
            for (i, mid) in memeIds.enumerated() {
                db.execute(
                    "UPDATE meme_collections SET sort_order=? WHERE meme_id=? AND collection_id=?",
                    [i, mid, collectionId]
                )
            }
        }
    }
}