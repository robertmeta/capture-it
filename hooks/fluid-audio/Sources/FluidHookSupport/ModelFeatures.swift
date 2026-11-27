@preconcurrency import CoreML
import Foundation

/// Copy model output arrays to owned CPU memory before an inference pool drains.
/// This prevents callers' feature accessors from extending GPU buffer lifetimes.
public enum ModelFeatures {
    /// Preserve feature values while giving each output array independent storage.
    public static func owned(_ provider: MLFeatureProvider) throws -> MLFeatureProvider {
        var values: [String: MLFeatureValue] = [:]
        for name in provider.featureNames {
            guard let value = provider.featureValue(for: name) else {
                throw HookFailure("Missing model output feature \(name)")
            }
            if let array = value.multiArrayValue {
                values[name] = MLFeatureValue(multiArray: try ownedArray(array))
            } else {
                values[name] = value
            }
        }
        return try MLDictionaryFeatureProvider(dictionary: values)
    }

    private static func ownedArray(_ source: MLMultiArray) throws -> MLMultiArray {
        let bytes: Int
        switch source.dataType {
        case .float16: bytes = MemoryLayout<UInt16>.stride
        case .float32, .int32: bytes = MemoryLayout<UInt32>.stride
        case .double: bytes = MemoryLayout<Double>.stride
        default: throw HookFailure("Unsupported model output array type \(source.dataType)")
        }
        var strides = Array(repeating: NSNumber(value: 1), count: source.shape.count)
        var stride = 1
        for dimension in source.shape.indices.reversed() {
            strides[dimension] = NSNumber(value: stride)
            stride *= source.shape[dimension].intValue
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: source.count * bytes, alignment: 64)
        let output: MLMultiArray
        do {
            output = try MLMultiArray(dataPointer: storage, shape: source.shape, dataType: source.dataType,
                                      strides: strides, deallocator: { $0.deallocate() })
        } catch {
            storage.deallocate()
            throw error
        }
        source.transfer(to: output)
        return output
    }
}
