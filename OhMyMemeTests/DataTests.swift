import XCTest
@testable import OhMyMeme

final class DataTests: XCTestCase {
    private func makeDb() -> MemeDb {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).db")
        return MemeDb(path: url.path)
    }

    private func bytes(_ arr: [UInt8]) -> Data { Data(arr) }

    func testSha256() {
        let data = Data("abc".utf8)
        XCTAssertEqual(
            FileUtils.sha256(data),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testMagicBytes() {
        XCTAssertEqual(FileUtils.detectExt(bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), ".png")
        XCTAssertEqual(FileUtils.detectExt(Data("GIF89a...".utf8)), ".gif")
        XCTAssertEqual(FileUtils.detectExt(bytes([0xFF, 0xD8, 0xFF, 0xE0])), ".jpg")
        var riff = Array("RIFF".utf8)
        riff += [0, 0, 0, 0]
        riff += Array("WEBP".utf8)
        XCTAssertEqual(FileUtils.detectExt(bytes(riff)), ".webp")
        XCTAssertEqual(FileUtils.detectExt(Data("BM".utf8)), ".bmp")
        XCTAssertEqual(FileUtils.detectExt(Data("hello".utf8)), "")
    }

    func testStemExt() {
        XCTAssertEqual(FileUtils.stem(fromName: "cat.gif"), "cat")
        XCTAssertEqual(FileUtils.ext(fromName: "CAT.GIF"), ".gif")
    }

    func testAnimated() {
        XCTAssertTrue(FileUtils.isAnimated(Data("GIF89a...".utf8)))
        XCTAssertFalse(FileUtils.isAnimated(Data("GIF87a...".utf8)))
        XCTAssertFalse(FileUtils.isAnimated(Data("hello".utf8)))
    }

    func testSchemaAndFlow() {
        let db = makeDb()
        XCTAssertEqual(db.count(), 0)

        let id1 = db.addMeme(
            filename: "a.png", fileHash: "h1", width: 10, height: 20,
            mimeType: "image/png", originalName: "猫猫"
        )
        let id2 = db.addMeme(
            filename: "b.gif", fileHash: "h2", width: 5, height: 5,
            mimeType: "image/gif", originalName: "狗狗", tags: ["宠物"]
        )

        XCTAssertEqual(db.getByHash("h1")?.id, id1)
        XCTAssertEqual(db.getByHash("h2")?.id, id2)
        XCTAssertEqual(db.getByFilename("a.png")?.id, id1)

        XCTAssertEqual(db.search(keyword: "猫猫").count, 1)
        XCTAssertEqual(db.search(keyword: "nope").count, 0)

        XCTAssertEqual(db.getAllTags(), ["宠物"])
        XCTAssertEqual(db.getMemeTags(id2), ["宠物"])
        db.setMemeTags(id2, ["动物"])
        XCTAssertEqual(db.getMemeTags(id2), ["动物"])
        XCTAssertEqual(db.getAllTags(), ["动物"])

        XCTAssertFalse(db.isFavorite(id1))
        XCTAssertTrue(db.toggleFavorite(id1))
        XCTAssertTrue(db.isFavorite(id1))
        XCTAssertEqual(db.search(favoriteOnly: true).map { $0.id }, [id1])

        let cid = db.createCollection(name: "工作")
        XCTAssertTrue(db.collectionExists(name: "工作", parentId: nil))
        db.addToCollection(id1, cid)
        XCTAssertEqual(db.search(collectionId: cid).map { $0.id }, [id1])
        XCTAssertEqual(db.search(uncategorizedOnly: true).map { $0.id }, [id2])
        db.removeFromCollection(id1, cid)
        XCTAssertEqual(db.search(collectionId: cid).count, 0)

        db.recordUse(id1)
        XCTAssertEqual(db.getRecent().map { $0.id }, [id1])

        db.reorderMemes([id2, id1])
        XCTAssertEqual(db.getAll().map { $0.id }, [id2, id1])

        db.deleteMeme(id1)
        XCTAssertNil(db.getById(id1))
        XCTAssertEqual(db.count(), 1)
    }

    func testUncategorizedCount() {
        let db = makeDb()
        let id1 = db.addMeme(filename: "x.png", fileHash: "u1")
        XCTAssertEqual(db.count(uncategorizedOnly: true), 1)
        let cid = db.createCollection(name: "g")
        db.addToCollection(id1, cid)
        XCTAssertEqual(db.count(uncategorizedOnly: true), 0)
    }

    func testDedup() throws {
        let db = makeDb()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        XCTAssertTrue(MemeImporter.importData(png, originalName: "pixel", db: db))
        XCTAssertFalse(MemeImporter.importData(png, originalName: "pixel2", db: db))

        let hash = FileUtils.sha256(png)
        let meme = try XCTUnwrap(db.getByHash(hash))
        XCTAssertEqual(meme.width, 1)
        XCTAssertEqual(meme.height, 1)

        let file = Thumbnailer.cacheFileURL(meme.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try? FileManager.default.removeItem(at: file)
    }
}