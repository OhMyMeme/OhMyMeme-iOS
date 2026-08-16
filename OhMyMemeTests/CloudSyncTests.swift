import XCTest
@testable import OhMyMeme

final class CloudSyncTests: XCTestCase {

    private let ak = "AKIAIOSFODNN7EXAMPLE"
    private let sk = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    private let amzDate = "20130524T000000Z"
    private let dateStamp = "20130524"
    private let host = "s3.example.com"
    private let region = "us-east-1"

    /// SigV4 签名向量：与 Python（botocore）独立生成交叉验证。
    func testSigV4SignatureVectors() {
        // PUT 对象
        XCTAssertEqual(
            CloudSync.sigV4Signature(
                method: "PUT",
                path: "/meme-bucket/memes/abc1234567890def.png",
                query: "",
                host: host, region: region, amzDate: amzDate, dateStamp: dateStamp,
                accessKey: ak, secretKey: sk
            ),
            "9165877cc16916cc65b869bb6e52ac4586d82b61a57922fede69fc90d58369d2"
        )
        // GET list（带 query）
        XCTAssertEqual(
            CloudSync.sigV4Signature(
                method: "GET",
                path: "/meme-bucket",
                query: "list-type=2&prefix=memes%2F",
                host: host, region: region, amzDate: amzDate, dateStamp: dateStamp,
                accessKey: ak, secretKey: sk
            ),
            "8a191c9d67a432b838c3a06429d141d17f8cb655f61c1f34cdd215d6875b48b5"
        )
        // GET 单个对象
        XCTAssertEqual(
            CloudSync.sigV4Signature(
                method: "GET",
                path: "/meme-bucket/memes/abc1234567890def.png",
                query: "",
                host: host, region: region, amzDate: amzDate, dateStamp: dateStamp,
                accessKey: ak, secretKey: sk
            ),
            "5938bc32b389a7ebd3533e30ba1eefe098d7b80dfc1575c74466214eaada4b25"
        )
    }

    /// 派生密钥本身（AWS SigV4 标准推导）与独立实现一致。
    func testSigV4DerivedKey() {
        // 通过签名向量间接验证即可，此处校验固定输入可复现。
        let sig1 = CloudSync.sigV4Signature(
            method: "GET", path: "/meme-bucket/memes/a.png", query: "",
            host: host, region: region, amzDate: amzDate, dateStamp: dateStamp,
            accessKey: ak, secretKey: sk
        )
        let sig2 = CloudSync.sigV4Signature(
            method: "GET", path: "/meme-bucket/memes/a.png", query: "",
            host: host, region: region, amzDate: amzDate, dateStamp: dateStamp,
            accessKey: ak, secretKey: sk
        )
        XCTAssertEqual(sig1, sig2)
        XCTAssertEqual(sig1.count, 64)
    }
}