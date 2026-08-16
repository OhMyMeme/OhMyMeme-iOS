import XCTest
@testable import OhMyMeme
#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class LanTests: XCTestCase {

    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    )!

    private func makeDb() -> MemeDb {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).db")
        return MemeDb(path: url.path)
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 加密原语（与桌面端 lan.py 交叉验证）

    func testHmacSha256Vector() {
        XCTAssertEqual(
            LanClient.hmacSha256(secret: "s3cret", nonce: "00112233445566778899aabbccddeeff"),
            "95d1860497cd61cf0b1acc0b4a5ec866a5295100ea812883ec4e014b635908fd"
        )
    }

    func testDeriveKeyVector() {
        XCTAssertEqual(
            hex(LanClient.deriveKey(secret: "s3cret")),
            "b98509c370a2603ecd8a1e059e715aa64db76a61d3688a35e5353803d6372905"
        )
        let empty = LanClient.deriveKey(secret: "")
        XCTAssertEqual(empty.count, 32)
        XCTAssertTrue(empty.allSatisfy { $0 == 0 })
    }

    func testFrameRoundTrip() throws {
        let key = LanClient.deriveKey(secret: "s3cret")
        let plain = Data("hello 局域网 🎉".utf8)
        let body = try LanClient.sealFrame(plain: plain, key: key)
        // 布局：iv(12) || ct || tag(16)
        XCTAssertEqual(body.count, 12 + plain.count + 16)
        XCTAssertEqual(try LanClient.unsealFrame(body, key: key), plain)
        // 篡改后解密失败
        var bad = body
        bad[bad.count - 1] ^= 0xFF
        XCTAssertThrowsError(try LanClient.unsealFrame(bad, key: key))
    }

    // MARK: - 清单辅助

    func testIsSafeRemoteFname() {
        XCTAssertTrue(Manifest.isSafeRemoteFname("a.png"))
        XCTAssertTrue(Manifest.isSafeRemoteFname("a b.png"))
        XCTAssertFalse(Manifest.isSafeRemoteFname(""))
        XCTAssertFalse(Manifest.isSafeRemoteFname("."))
        XCTAssertFalse(Manifest.isSafeRemoteFname(".."))
        XCTAssertFalse(Manifest.isSafeRemoteFname(".hidden"))
        XCTAssertFalse(Manifest.isSafeRemoteFname("/etc/passwd"))
        XCTAssertFalse(Manifest.isSafeRemoteFname("..\\x"))
        XCTAssertFalse(Manifest.isSafeRemoteFname("a/b.png"))
        XCTAssertFalse(Manifest.isSafeRemoteFname("a\\b.png"))
        XCTAssertFalse(Manifest.isSafeRemoteFname("~tmp"))
    }

    func testBuildManifestAndApply() {
        let db = makeDb()
        let id1 = db.addMeme(filename: "a.png", fileHash: "ha", originalName: "猫猫")
        let id2 = db.addMeme(filename: "b.gif", fileHash: "hb", originalName: "")
        let cid = db.createCollection(name: "工作")
        db.addToCollection(id1, cid)

        let manifest = Manifest.buildManifest(db: db)
        XCTAssertEqual(manifest["version"] as? Int, 3)
        let memes = manifest["memes"] as? [[String: Any]] ?? []
        XCTAssertEqual(memes.count, 2)
        XCTAssertEqual(memes.first?["filename"] as? String, "a.png")
        XCTAssertEqual(memes.first?["name"] as? String, "猫猫")
        XCTAssertEqual(memes.first?["sha256"] as? String, "ha")
        // b.gif 无 original_name，回退去扩展名
        XCTAssertEqual(memes.last?["name"] as? String, "b")
        let colls = manifest["collections"] as? [[String: Any]] ?? []
        XCTAssertEqual(colls.count, 1)
        XCTAssertEqual(colls.first?["name"] as? String, "工作")
        XCTAssertEqual(colls.first?["filenames"] as? [String], ["a.png"])
        XCTAssertEqual(id2, db.getByFilename("b.gif")?.id)

        // applyRemoteOrder：远端顺序 b.gif 在前
        let remote: [String: Any] = [
            "version": 3,
            "memes": [
                ["filename": "b.gif"],
                ["filename": "a.png"]
            ],
            "collections": []
        ]
        Manifest.applyRemoteOrder(db: db, manifest: remote)
        XCTAssertEqual(db.getAll().map { $0.id }, [id2, id1])

        // applyRemoteCollections：远端新增分组
        let remote2: [String: Any] = [
            "version": 3,
            "memes": [],
            "collections": [
                ["name": "表情包", "filenames": ["a.png", "b.gif"]]
            ]
        ]
        Manifest.applyRemoteCollections(db: db, manifest: remote2)
        let cid2 = db.createCollection(name: "表情包")
        XCTAssertEqual(db.search(collectionId: cid2).map { $0.id }.count, 2)
    }

    // MARK: - 回环集成（迷你 lan.py 服务端）

    func testConnectPingPullPush() throws {
        let server = MiniLanServer(secret: "s3cret", files: ["a.png": png], names: ["a.png": "测试"])
        let port = try server.start()
        defer { server.stop() }

        let conn = try LanClient.connect(ip: "127.0.0.1", port: port, secret: "s3cret")
        XCTAssertTrue(conn.ping())
        XCTAssertTrue(conn.allowSecretConfig)

        // pull_manifest
        let manifest = try conn.pullManifest()
        let memes = manifest["memes"] as? [[String: Any]] ?? []
        XCTAssertEqual(memes.count, 1)
        XCTAssertEqual(memes.first?["filename"] as? String, "a.png")

        // pull_file 往返
        let data = try conn.pullFile(filename: "a.png")
        XCTAssertEqual(data, png)
        // push_file 往返
        try conn.pushFile(filename: "b.gif", data: png)
        XCTAssertEqual(try conn.pullFile(filename: "b.gif"), png)

        // 完整 pull：清单 → 导入入库
        let db = makeDb()
        let pullResult = try LanClient.pull(db: db, conn: conn)
        XCTAssertEqual(pullResult.pulled, 1)
        XCTAssertEqual(db.count(), 1)
        let imported = try XCTUnwrap(db.getByHash(FileUtils.sha256(png)))
        XCTAssertEqual(imported.originalName, "测试")
        XCTAssertEqual(imported.fileHash, FileUtils.sha256(png))
        cleanup(meme: imported, db: db)

        // 完整 push：本地 meme → push_file + push_manifest
        let db2 = makeDb()
        let server2 = MiniLanServer(secret: "s3cret")
        let port2 = try server2.start()
        defer { server2.stop() }
        let conn2 = try LanClient.connect(ip: "127.0.0.1", port: port2, secret: "s3cret")
        let fname = "push-\(UUID().uuidString.prefix(8)).png"
        let cacheURL = Thumbnailer.cacheFileURL(fname)
        try png.write(to: cacheURL)
        let mid = db2.addMeme(filename: fname, fileHash: FileUtils.sha256(png), width: 1, height: 1, originalName: "推送")
        let pushResult = try LanClient.push(db: db2, conn: conn2)
        XCTAssertEqual(pushResult.pushed, 1)
        XCTAssertEqual(server2.files()[fname], png as Data?)
        try? FileManager.default.removeItem(at: cacheURL)
        db2.deleteMeme(mid)

        conn.close()
        conn2.close()
    }

    func testPullWrongSecretFails() throws {
        let server = MiniLanServer(secret: "s3cret")
        let port = try server.start()
        defer { server.stop() }
        XCTAssertThrowsError(try LanClient.connect(ip: "127.0.0.1", port: port, secret: "wrong"))
    }

    private func cleanup(meme: Meme, db: MemeDb) {
        let file = Thumbnailer.cacheFileURL(meme.filename)
        try? FileManager.default.removeItem(at: file)
        db.deleteMeme(meme.id)
    }
}

/// 迷你 lan.py 兼容服务端（仅测试用）
private final class MiniLanServer {
    private let secret: String
    private var fileStore: [String: Data]
    private var nameStore: [String: String]
    private var serverFD: Int32 = -1
    private var thread: Thread?
    private(set) var port = 0

    init(secret: String, files: [String: Data] = [:], names: [String: String] = [:]) {
        self.secret = secret
        self.fileStore = files
        self.nameStore = names
    }

    func files() -> [String: Data] { fileStore }

    func start() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LanClient.LanError("socket 失败") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let b = withUnsafePointer(to: &addr) { aptr in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard b == 0 else { throw LanClient.LanError("bind 失败") }
        listen(fd, 4)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { aptr in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = Int(addr.sin_port.bigEndian)
        serverFD = fd
        thread = Thread { [weak self] in self?.acceptLoop() }
        thread?.start()
        return port
    }

    func stop() {
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
    }

    private func acceptLoop() {
        while serverFD >= 0 {
            var peer = sockaddr_in()
            var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let c = withUnsafeMutablePointer(to: &peer) { aptr in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(serverFD, $0, &peerLen) }
            }
            guard c >= 0 else { break }
            handleClient(c)
        }
    }

    private func handleClient(_ c: Int32) {
        defer { close(c) }
        var key = Data(count: 32)
        if !secret.isEmpty {
            let nonce = (0..<16).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
            guard (try? sendPlain(c, ["t": "challenge", "nonce": nonce])) != nil,
                  let proof = try? recvPlain(c),
                  proof["t"] as? String == "proof",
                  (proof["mac"] as? String) == LanClient.hmacSha256(secret: secret, nonce: nonce)
            else {
                try? sendPlain(c, ["t": "no"])
                return
            }
            guard (try? sendPlain(c, ["t": "ok"])) != nil else { return }
        } else {
            guard (try? sendPlain(c, ["t": "ok"])) != nil else { return }
        }
        key = LanClient.deriveKey(secret: secret)

        while true {
            guard let msg = try? recvFrame(c, key),
                  let cmd = msg["cmd"] as? String
            else { break }
            let resp: [String: Any]
            switch cmd {
            case "device_info":
                resp = ["ok": true, "approved": true, "allow_secret_config": true]
            case "ping":
                resp = ["ok": true, "ver": "0.1.0"]
            case "pull_manifest":
                resp = ["ok": true, "manifest": buildManifest()]
            case "push_manifest":
                resp = ["ok": true, "local_count": 0]
            case "pull_file":
                let fname = msg["filename"] as? String ?? ""
                if let data = fileStore[fname] {
                    resp = ["ok": true, "filename": fname, "data": data.base64EncodedString()]
                } else {
                    resp = ["ok": false, "error": "文件不存在"]
                }
            case "push_file":
                let fname = msg["filename"] as? String ?? ""
                if let b64 = msg["data"] as? String, let data = Data(base64Encoded: b64) {
                    fileStore[fname] = data
                    resp = ["ok": true, "filename": fname]
                } else {
                    resp = ["ok": false, "error": "缺少文件数据"]
                }
            case "get_config":
                resp = ["ok": true, "config": ["language": "zh-CN"]]
            case "send_config":
                resp = ["ok": true]
            default:
                resp = ["ok": false, "error": "未知命令: \(cmd)"]
            }
            guard (try? sendFrame(c, key, resp)) != nil else { break }
        }
    }

    private func buildManifest() -> [String: Any] {
        var memes: [[String: Any]] = []
        for (fname, data) in fileStore.sorted(by: { $0.key < $1.key }) {
            memes.append([
                "filename": fname,
                "name": nameStore[fname] ?? FileUtils.stem(fromName: fname),
                "sha256": FileUtils.sha256(data),
                "file_size": data.count
            ])
        }
        return ["version": 3, "memes": memes, "collections": []]
    }

    // MARK: - 帧读写

    private func sendAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { return }
            var total = 0
            while total < data.count {
                let w = send(fd, base.advanced(by: total), data.count - total, 0)
                if w <= 0 { throw LanClient.LanError("发送失败") }
                total += w
            }
        }
    }

    private func readExact(_ fd: Int32, _ n: Int) throws -> Data {
        var buf = Data(count: n)
        var total = 0
        while total < n {
            let r = buf.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return recv(fd, base.advanced(by: total), n - total, 0)
            }
            if r <= 0 { throw LanClient.LanError("连接关闭") }
            total += r
        }
        return buf
    }

    private func readUInt32(_ fd: Int32) throws -> UInt32 {
        let hdr = try readExact(fd, 4)
        let b = [UInt8](hdr)
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    private func uint32BEData(_ v: Int) -> Data {
        let u = UInt32(v).bigEndian
        return withUnsafeBytes(of: u) { Data($0) }
    }

    private func sendPlain(_ fd: Int32, _ obj: [String: Any]) throws {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { throw LanClient.LanError("序列化失败") }
        try sendAll(fd, uint32BEData(data.count) + data)
    }

    private func recvPlain(_ fd: Int32) throws -> [String: Any] {
        let ln = try readUInt32(fd)
        guard ln <= LanProtocol.maxFrame else { throw LanClient.LanError("帧过大") }
        let body = try readExact(fd, Int(ln))
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw LanClient.LanError("JSON 解析失败")
        }
        return obj
    }

    private func sendFrame(_ fd: Int32, _ key: Data, _ obj: [String: Any]) throws {
        guard let plain = try? JSONSerialization.data(withJSONObject: obj) else { throw LanClient.LanError("序列化失败") }
        let body = try LanClient.sealFrame(plain: plain, key: key)
        try sendAll(fd, uint32BEData(body.count) + body)
    }

    private func recvFrame(_ fd: Int32, _ key: Data) throws -> [String: Any] {
        let ln = try readUInt32(fd)
        guard ln <= LanProtocol.maxFrame, ln >= LanProtocol.ivLen + LanProtocol.tagLen else {
            throw LanClient.LanError("帧长度非法")
        }
        let body = try readExact(fd, Int(ln))
        let plain = try LanClient.unsealFrame(body, key: key)
        guard let obj = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else {
            throw LanClient.LanError("JSON 解析失败")
        }
        return obj
    }
}
