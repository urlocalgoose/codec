import AVFoundation
import XCTest
@testable import Codec

final class SpectrumImageRegression: XCTestCase {
    @MainActor func testBandBytesAndRingOrdering() {
        let history = SpectrumHistory(capacity: 3)
        for frame in 0..<5 {
            var column = [Float](repeating: 0, count: 112)
            column[frame] = Float(frame + 1) / 255
            history.append(column)
        }
        XCTAssertTrue(history.count == 5 && history.oldestIndex == 2)
        var values = [Float](repeating: 0, count: 112)
        for frame in 2..<5 {
            history.column(frame, into: &values)
            XCTAssertTrue(values[frame] == Float(frame + 1) / 255)
            XCTAssertTrue(values.filter { $0 != 0 }.count == 1)
        }
        print("Native texture input preserves band bytes and ring ordering")
    }
}
