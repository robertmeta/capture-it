import CoreML
import XCTest
@testable import FluidHookSupport

final class ModelFeaturesTests: XCTestCase {
    func testOutputFeaturesHaveIndependentContiguousStorage() throws {
        let original = MLMultiArray(shape: [2, 3], dataType: .float32, strides: [4, 1])
        for row in 0..<2 {
            for column in 0..<3 {
                original[[NSNumber(value: row), NSNumber(value: column)]] = NSNumber(value: row * 10 + column)
            }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["samples": original, "label": "kept"])
        let copy = try ModelFeatures.owned(provider)
        let array = try XCTUnwrap(copy.featureValue(for: "samples")?.multiArrayValue)
        XCTAssertEqual(array.shape, original.shape)
        XCTAssertEqual(array.strides, [3, 1])
        XCTAssertEqual(array.dataType, original.dataType)
        original[[0, 0]] = 999
        XCTAssertEqual(array[[0, 0]], 0)
        XCTAssertEqual(array[[1, 2]], 12)
        XCTAssertEqual(copy.featureValue(for: "label")?.stringValue, "kept")
    }

    func testSupportedArrayTypesPreserveTheirValues() throws {
        for type: MLMultiArrayDataType in [.float16, .float32, .double, .int32] {
            let input = try MLMultiArray(shape: [2], dataType: type)
            input[0] = 3; input[1] = -2
            let provider = try MLDictionaryFeatureProvider(dictionary: ["value": input])
            let result = try ModelFeatures.owned(provider)
            let output = try XCTUnwrap(result.featureValue(for: "value")?.multiArrayValue)
            XCTAssertEqual(output.dataType, type)
            XCTAssertEqual(output[0], 3)
            XCTAssertEqual(output[1], -2)
        }
    }
}
