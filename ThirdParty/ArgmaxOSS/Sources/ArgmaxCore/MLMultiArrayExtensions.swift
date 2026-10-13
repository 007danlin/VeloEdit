//  For licensing see accompanying LICENSE.md file.
//  Copyright © 2024 Argmax, Inc. All rights reserved.

import Accelerate
import CoreML

// MARK: - MLMultiArray Creation

public extension MLMultiArray {
    /// Creates an MLMultiArray pre-filled with an initial value.
    /// Uses IOSurface-backed storage for float16 arrays.
    convenience init(shape: [NSNumber], dataType: MLMultiArrayDataType, initialValue: Any) throws {
        switch dataType {
            case .float16:
                guard let pixelBuffer = Self.pixelBuffer(for: shape) else {
                    throw MLMultiArrayCreationError.pixelBufferFailed
                }
                self.init(pixelBuffer: pixelBuffer, shape: shape)
            default:
                try self.init(shape: shape, dataType: dataType)
        }

        switch dataType {
            case .double:
                if let value = initialValue as? Double {
                    let typedPointer = dataPointer.bindMemory(to: Double.self, capacity: count)
                    typedPointer.initialize(repeating: value, count: count)
                }
            case .float32:
                if let value = initialValue as? Float {
                    let typedPointer = dataPointer.bindMemory(to: Float.self, capacity: count)
                    typedPointer.initialize(repeating: value, count: count)
                }
            case .float16:
                if let value = initialValue as? FloatType {
                    let bits = Self.float16Bits(value)
                    // IOSurface rows can have padding. Initialize the actual
                    // storage as 16-bit words, even when FloatType is Float.
                    withUnsafeMutableBytes { bytes, _ in
                        bytes.bindMemory(to: UInt16.self).initialize(repeating: bits)
                    }
                }
            case .int32:
                if let value = initialValue as? Int32 {
                    let typedPointer = dataPointer.bindMemory(to: Int32.self, capacity: count)
                    typedPointer.initialize(repeating: value, count: count)
                }
            #if compiler(>=6.2)
            case .int8:
                if #available(macOS 26.0, iOS 26.0, watchOS 26.0, visionOS 26.0, tvOS 26.0, *),
                   let value = initialValue as? Int8 {
                    let typedPointer = dataPointer.bindMemory(to: Int8.self, capacity: count)
                    typedPointer.initialize(repeating: value, count: count)
                }
            #endif
            @unknown default:
                break
        }
    }

    /// Creates an MLMultiArray from an [Int] array.
    /// Values are stored in the last dimension (default is dims=1).
    static func from(_ array: [Int], dims: Int = 1) throws -> MLMultiArray {
        var shape = Array(repeating: 1, count: dims)
        shape[shape.count - 1] = array.count
        let output = try MLMultiArray(shape: shape as [NSNumber], dataType: .int32)
        let pointer = UnsafeMutablePointer<Int32>(OpaquePointer(output.dataPointer))
        for (i, item) in array.enumerated() {
            pointer[i] = Int32(item)
        }
        return output
    }
}

// MARK: - MLMultiArray Indexing & Fill

public extension MLMultiArray {
    /// Size of the model's stored scalar, independent of the host's FloatType.
    var scalarByteCount: Int {
        switch dataType {
        case .float16: return 2
        case .float32, .int32: return 4
        case .double: return 8
        #if compiler(>=6.2)
        case .int8: return 1
        #endif
        @unknown default: preconditionFailure("Unsupported MLMultiArray storage")
        }
    }

    /// BNNS uses the host's arithmetic type; Core ML outputs may still be FP16.
    func forFloatTypeComputation() -> MLMultiArray {
        let expected: MLMultiArrayDataType = MemoryLayout<FloatType>.size == 2 ? .float16 : .float32
        if dataType == expected { return self }
        return MLMultiArray(MLShapedArray<FloatType>(converting: self))
    }

    private static func float16Bits(_ value: FloatType) -> UInt16 {
        #if arch(x86_64)
        // Swift's native Float16 arithmetic is unavailable on Intel macOS.
        var source = Float(value)
        var result: UInt16 = 0
        withUnsafeMutablePointer(to: &source) { input in
            withUnsafeMutablePointer(to: &result) { output in
                var src = vImage_Buffer(data: input, height: 1, width: 1, rowBytes: 4)
                var dst = vImage_Buffer(data: output, height: 1, width: 1, rowBytes: 2)
                precondition(vImageConvert_PlanarFtoPlanar16F(&src, &dst, vImage_Flags(kvImageNoFlags)) == kvImageNoError)
            }
        }
        return result
        #else
        return value.bitPattern
        #endif
    }

    /// Computes the linear offset from multi-dimensional indices using strides.
    @inline(__always)
    func linearOffset(for index: [Int], strides strideInts: [Int]? = nil) -> Int {
        var linearOffset = 0
        let strideInts = strideInts ?? strides.map { $0.intValue }
        for (dimension, stride) in zip(index, strideInts) {
            linearOffset += dimension * stride
        }
        return linearOffset
    }

    @available(*, deprecated, message: "Use linearOffset(for: [Int], strides:) instead.")
    @inline(__always)
    func linearOffset(for index: [NSNumber], strides strideInts: [Int]? = nil) -> Int {
        linearOffset(for: index.map(\.intValue), strides: strideInts)
    }

    /// Fills a range of indices in the last dimension with a value.
    /// Requires shape [1, 1, n].
    func fillLastDimension(indexes: Range<Int>, with value: FloatType) {
        precondition(shape.count == 3 && shape[0] == 1 && shape[1] == 1, "Must have [1, 1, n] shape")
        let validIndexes = indexes.clamped(to: 0..<shape[2].intValue)
        if dataType == .float16 {
            let bits = Self.float16Bits(value)
            withUnsafeMutableBytes { bytes, strides in
                let words = bytes.bindMemory(to: UInt16.self)
                for index in validIndexes { words[index * strides[2]] = bits }
            }
        } else {
            for index in validIndexes { self[[0, 0, NSNumber(value: index)]] = NSNumber(value: Double(value)) }
        }
    }

    /// Fills specific multi-dimensional indices with a value.
    func fill<Value>(indexes: [[Int]], with value: Value) {
        let halfBits = dataType == .float16 ? (value as? FloatType).map(Self.float16Bits) : nil
        let strideInts = strides.map { $0.intValue }
        let shapeInts = shape.map { $0.intValue }
        for index in indexes {
            guard index.count == shapeInts.count,
                  zip(index, shapeInts).allSatisfy({ $0 >= 0 && $0 < $1 }) else {
                continue
            }
            let linearOffset = linearOffset(for: index, strides: strideInts)
            if let halfBits {
                dataPointer.storeBytes(of: halfBits, toByteOffset: linearOffset * 2, as: UInt16.self)
            } else if let scalar = value as? FloatType, dataType == .float32 {
                dataPointer.storeBytes(of: Float(scalar), toByteOffset: linearOffset * 4, as: Float.self)
            } else {
                let pointer = UnsafeMutablePointer<Value>(OpaquePointer(dataPointer))
                pointer[linearOffset] = value
            }
        }
    }

    @available(*, deprecated, message: "Use fill(indexes: [[Int]], with:) instead.")
    func fill<Value>(indexes: [[NSNumber]], with value: Value) {
        fill(indexes: indexes.map { $0.map(\.intValue) }, with: value)
    }
}

// MARK: - IOSurface-backed Pixel Buffer

extension MLMultiArray {
    /// Creates a CVPixelBuffer suitable for float16 IOSurface-backed MLMultiArrays.
    public class func pixelBuffer(for shape: [NSNumber]) -> CVPixelBuffer? {
        guard let width = shape.last?.intValue else { return nil }
        let height = shape[0..<shape.count - 1].reduce(1) { $0 * $1.intValue }

        var pixelBuffer: CVPixelBuffer?
        let createReturn = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent16Half,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard createReturn == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }
}

// MARK: - Error

/// Error thrown when MLMultiArray creation fails.
@frozen
public enum MLMultiArrayCreationError: Error, LocalizedError {
    case pixelBufferFailed

    public var errorDescription: String? {
        switch self {
        case .pixelBufferFailed:
            return "Failed to create IOSurface-backed pixel buffer for MLMultiArray"
        }
    }
}

