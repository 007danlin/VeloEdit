import XCTest
import CoreML
import ArgmaxCore
@testable import WhisperKit

final class StorageTests: XCTestCase {
    private func tensor(_ shape: [Int], _ type: MLMultiArrayDataType = .float16, value: Float = 0) throws -> MLMultiArray {
        try MLMultiArray(shape: shape.map(NSNumber.init), dataType: type, initialValue: FloatType(value))
    }

    // Explicit padding catches code that assumes every row is tightly packed.
    private func strided(_ shape: [Int], _ strides: [Int], _ type: MLMultiArrayDataType = .float16) throws -> MLMultiArray {
        let bytes = type == .float16 ? 2 : 4
        let span = zip(shape, strides).reduce(1) { $0 + ($1.0 - 1) * $1.1 }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: span * bytes + 256, alignment: 64)
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: span * bytes + 256)
        return try MLMultiArray(dataPointer: pointer, shape: shape.map(NSNumber.init), dataType: type,
                               strides: strides.map(NSNumber.init), deallocator: { $0.deallocate() })
    }

    func testHalfInitializationAcrossPaddedRows() throws {
        for shape in [[1, 1, 1, 8], [3, 17], [1, 64, 1, 224]] {
            let array = try tensor(shape, value: -10000)
            for index in 0..<array.count { XCTAssertEqual(array[index].floatValue, -10000) }
        }
    }

    func testSparseAndRangeMaskingPreserveNeighbors() throws {
        for type in [MLMultiArrayDataType.float16, .float32] {
            let array = try strided([1, 1, 9], [40, 40, 3], type)
            for i in 0..<array.count { array[i] = NSNumber(value: i + 1) }
            array.fill(indexes: [[0, 0, 2], [-1, 0, 1], [0, 0, 99]], with: -FloatType.infinity)
            array.fillLastDimension(indexes: 5..<8, with: -FloatType.infinity)
            for i in 0..<array.count {
                XCTAssertEqual(array[i].floatValue, [2, 5, 6, 7].contains(i) ? -.infinity : Float(i + 1))
            }
        }
    }

    func testKVCacheUsesStorageWidthAndIndependentStrides() throws {
        for type in [MLMultiArrayDataType.float16, .float32] {
            let key = try strided([1, 3, 1, 7], [96, 24, 24, 2], type)
            let value = try strided([1, 3, 1, 7], [128, 32, 32, 3], type)
            let keySlice = try strided([1, 3, 1, 2], [24, 8, 8, 2], type)
            let valueSlice = try strided([1, 3, 1, 2], [48, 16, 16, 3], type)
            for row in 0..<3 {
                for column in 0..<2 {
                    keySlice[[0, NSNumber(value: row), 0, NSNumber(value: column)]] = NSNumber(value: row * 10 + column + 1)
                    valueSlice[[0, NSNumber(value: row), 0, NSNumber(value: column)]] = NSNumber(value: row * 10 + column + 101)
                }
            }
            TextDecoder.updateKVCache(keyTensor: key, keySlice: keySlice, valueTensor: value, valueSlice: valueSlice, insertAtIndex: 3)
            for row in 0..<3 {
                for column in 0..<7 {
                    let index = [0, row, 0, column].map(NSNumber.init)
                    let populated = (3..<5).contains(column)
                    XCTAssertEqual(key[index].intValue, populated ? row * 10 + column - 2 : 0)
                    XCTAssertEqual(value[index].intValue, populated ? row * 10 + column + 98 : 0)
                }
            }
        }
    }

    func testAlignmentUpdatePreservesOtherRows() throws {
        let target = try strided([5, 7], [24, 2])
        let slice = try strided([1, 7], [32, 3])
        for i in 0..<7 { slice[i] = NSNumber(value: i + 1) }
        TextDecoder.updateAlignmentWeights(alignmentTensor: target, alignmentSlice: slice, insertAtIndex: 1)
        for row in 0..<5 {
            for col in 0..<7 {
                XCTAssertEqual(target[[NSNumber(value: row), NSNumber(value: col)]].intValue, row == 2 ? col + 1 : 0)
            }
        }
    }

    func testWordAlignmentRowSelectionPreservesPadding() throws {
        for type in [MLMultiArrayDataType.float16, .float32] {
            let weights = try strided([5, 17], [64, 2], type)
            for row in 0..<5 {
                for col in 0..<17 { weights[[NSNumber(value: row), NSNumber(value: col)]] = NSNumber(value: row * 20 + col) }
            }
            let selected = try SegmentSeeker.selectAlignmentRows([4, 1, 3], from: weights)
            for (row, original) in [4, 1, 3].enumerated() {
                for col in 0..<17 { XCTAssertEqual(selected[[NSNumber(value: row), NSNumber(value: col)]].intValue, original * 20 + col) }
            }
        }
    }

    func testHalfLogitsConversionAndSuppression() throws {
        let logits = try tensor([1, 1, 4])
        for (i, value) in [1.5, -2.0, 3.25, 10.0].enumerated() { logits[i] = NSNumber(value: value) }
        _ = SuppressTokensFilter(suppressTokens: [3]).filterLogits(logits, withTokens: [])
        let converted = logits.forFloatTypeComputation()
        XCTAssertEqual(converted.scalarByteCount, MemoryLayout<FloatType>.size)
        XCTAssertEqual((0..<4).map { converted[$0].floatValue }, [1.5, -2, 3.25, -.infinity])
    }

    func testBNNSSamplingFromHalfLogits() throws {
        let logits = try tensor([1, 1, 4])
        for (i, value) in [0, 1, 4, -2].enumerated() { logits[i] = NSNumber(value: value) }
        let sampler = GreedyTokenSampler(temperature: 0, eotToken: 99, decodingOptions: DecodingOptions())
        let result = sampler.sampleWithBNNS(logits: logits)
        XCTAssertEqual(result.token, 2)
        XCTAssertEqual(result.logprob, -log(1 + exp(-4) + exp(-3) + exp(-6)), accuracy: 0.002)
    }

    func testCurrentOSSamplingFromHalfLogits() async throws {
        let logits = try tensor([1, 1, 4])
        for (i, value) in [0, 1, 4, -2].enumerated() { logits[i] = NSNumber(value: value) }
        let sampler = GreedyTokenSampler(temperature: 0, eotToken: 99, decodingOptions: DecodingOptions())
        let result = await sampler.update(tokens: [7], logits: logits, logProbs: [0])
        XCTAssertEqual(result.tokens, [7, 2])
        XCTAssertEqual(result.logProbs.last!, -log(1 + exp(-4) + exp(-3) + exp(-6)), accuracy: 0.002)
    }

    func testTimestampProbabilityUsesHalfStorageCorrectly() throws {
        let tokens = SpecialTokens(endToken: 0, englishToken: 0, noSpeechToken: 0, noTimestampsToken: 0,
                                   specialTokenBegin: 0, startOfPreviousToken: 0, startOfTranscriptToken: 0,
                                   timeTokenBegin: 3, transcribeToken: 0, translateToken: 0, whitespaceToken: 0)
        let filter = TimestampRulesFilter(specialTokens: tokens, sampleBegin: 0, maxInitialTimestampIndex: nil, isModelMultilingual: false)
        let logits = try tensor([1, 1, 5])
        for (i, value) in [0, 0, 0, 3, 3].enumerated() { logits[i] = NSNumber(value: value) }
        XCTAssertTrue(filter.sumOfProbabilityOverTimestampsIsAboveAnyOtherToken(logits: logits, timeTokenBegin: 3))
        logits[0] = 10
        XCTAssertFalse(filter.sumOfProbabilityOverTimestampsIsAboveAnyOtherToken(logits: logits, timeTokenBegin: 3))
    }
}
