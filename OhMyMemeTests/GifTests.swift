import XCTest
@testable import OhMyMeme

final class GifTests: XCTestCase {

    private func gradientRGBA(width: Int, height: Int) -> [UInt8] {
        var rgba: [UInt8] = []
        rgba.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                rgba.append(UInt8(x * 36 & 0xFF))
                rgba.append(UInt8(y * 36 & 0xFF))
                rgba.append(UInt8((x + y) * 18 & 0xFF))
                rgba.append(255)
            }
        }
        return rgba
    }

    func testEncodeHeaderAndTrailer() {
        let rgba = gradientRGBA(width: 8, height: 8)
        let gif = GifEncoder.encode(rgba: rgba, width: 8, height: 8)
        XCTAssertEqual(Array(gif[0..<6]), Array("GIF89a".utf8))
        XCTAssertEqual(gif.last, 0x3B)
        // 全局色板 256 色
        XCTAssertEqual(gif[10] & 0x07, 0x07)
    }

    func testRoundTripLosslessUnder256Colors() {
        let rgba = gradientRGBA(width: 8, height: 8)
        let gif = GifEncoder.encode(rgba: rgba, width: 8, height: 8)
        let res = try! XCTUnwrap(GifFrameDecoder.decode(gif))
        XCTAssertEqual(res.width, 8)
        XCTAssertEqual(res.height, 8)
        XCTAssertEqual(res.rgb.count, 8 * 8 * 3)
        // <=256 色时为直接映射，像素逐字节一致（丢弃 alpha）
        for i in 0..<res.rgb.count {
            let src = (i / 3) * 4 + (i % 3)
            XCTAssertEqual(res.rgb[i], rgba[src])
        }
    }

    func testEncodeDeterministic() {
        let rgba = gradientRGBA(width: 8, height: 8)
        XCTAssertEqual(
            GifEncoder.encode(rgba: rgba, width: 8, height: 8),
            GifEncoder.encode(rgba: rgba, width: 8, height: 8)
        )
    }

    func testMedianCutOver256Colors() {
        // 32x32 全随机色 → 1024 种颜色，走 median cut 量化
        var rgba = gradientRGBA(width: 32, height: 32)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = UInt8((rgba[i] &* 7 &+ 11) & 0xFF)
        }
        let gif = GifEncoder.encode(rgba: rgba, width: 32, height: 32)
        let res = try! XCTUnwrap(GifFrameDecoder.decode(gif))
        XCTAssertEqual(res.width, 32)
        XCTAssertEqual(res.height, 32)
        XCTAssertEqual(res.rgb.count, 32 * 32 * 3)
    }

    func testRejectNonGif() {
        XCTAssertNil(GifFrameDecoder.decode(Array("not a gif".utf8)))
        XCTAssertNil(GifFrameDecoder.decode(Array("GIF89a".utf8)))
    }
}