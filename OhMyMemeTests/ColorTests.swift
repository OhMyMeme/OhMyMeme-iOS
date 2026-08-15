import XCTest
@testable import OhMyMeme

final class ColorTests: XCTestCase {
    func testHex() {
        let c = UIColor(hex: 0x3B82F6)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(Int((r * 255).rounded()), 0x3B)
        XCTAssertEqual(Int((g * 255).rounded()), 0x82)
        XCTAssertEqual(Int((b * 255).rounded()), 0xF6)
        XCTAssertEqual(a, 1)
    }
}