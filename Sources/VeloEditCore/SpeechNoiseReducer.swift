import AVFoundation
import CRNNoise

/// Offline speech enhancement with the bundled RNNoise 0.2 network.
/// Each channel has independent recurrent state; memory use is independent of
/// clip length. No audio or model download leaves the machine.
enum SpeechNoiseReducer {
    static let sampleRate = 48_000.0
    // 0.2 delays the spectrum by one hop, in addition to the synthesis overlap.
    private static let latencyFrames = 2

    static func render(source: URL, destination: URL, amount: Double) async throws {
        try Task.checkCancellation()
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard format.sampleRate == sampleRate, format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved, format.channelCount > 0, input.length > 0 else {
            throw DerivedMediaError.exportFailed("Неверный формат звука для шумоподавления")
        }
        let frameSize = Int(rnnoise_get_frame_size())
        let channelCount = Int(format.channelCount)
        var states: [OpaquePointer] = []
        defer { states.forEach { rnnoise_destroy($0) } }
        for _ in 0..<channelCount {
            guard let state = rnnoise_create(nil) else {
                throw DerivedMediaError.exportFailed("Не удалось запустить шумоподавление")
            }
            states.append(state)
        }
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameSize)),
              let writeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameSize)),
              let readChannels = readBuffer.floatChannelData,
              let writeChannels = writeBuffer.floatChannelData else {
            throw DerivedMediaError.cannotCreateDestination
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        // Drain Objective-C autoreleases at creation, then release explicitly
        // before publishing: an open CAF can hide its final buffered samples.
        var output: AVAudioFile? = try autoreleasepool { try AVAudioFile(forWriting: destination, settings: settings) }
        defer { output = nil }
        let strength = amount.isFinite ? min(1, max(0, amount)) : 0
        // Give the middle of the existing slider useful suppression while
        // retaining a continuous path to the unprocessed recording at zero.
        let wet = Float(1 - pow(1 - strength, 2))
        let ringSize = latencyFrames + 1
        var dry = Array(repeating: Array(repeating: Float.zero, count: frameSize * channelCount), count: ringSize)
        var scaled = [Float](repeating: 0, count: frameSize)
        var denoised = [Float](repeating: 0, count: frameSize)
        let blocks = Int((input.length + Int64(frameSize) - 1) / Int64(frameSize))
        var written: Int64 = 0
        for block in 0..<(blocks + latencyFrames) {
            try Task.checkCancellation()
            if block % 100 == 0 { await Task.yield() }
            if block < blocks {
                try input.read(into: readBuffer, frameCount: AVAudioFrameCount(frameSize))
            } else {
                readBuffer.frameLength = 0
            }
            let readCount = Int(readBuffer.frameLength)
            let slot = block % ringSize
            let outputSlot = (block + ringSize - latencyFrames) % ringSize
            let outputCount = block >= latencyFrames ? Int(min(Int64(frameSize), input.length - written)) : 0
            for channel in 0..<channelCount {
                for index in 0..<frameSize {
                    let value = index < readCount ? readChannels[channel][index] : 0
                    let finite = value.isFinite ? value : 0
                    dry[slot][channel * frameSize + index] = finite
                    // RNNoise expects floats in signed 16-bit PCM amplitude units.
                    scaled[index] = min(1, max(-1, finite)) * 32_768
                }
                scaled.withUnsafeBufferPointer { source in
                    denoised.withUnsafeMutableBufferPointer { target in
                        _ = rnnoise_process_frame(states[channel], target.baseAddress!, source.baseAddress!)
                    }
                }
                for index in 0..<outputCount {
                    let clean = denoised[index] / 32_768
                    guard clean.isFinite else {
                        throw DerivedMediaError.exportFailed("Шумоподавление вернуло повреждённый звук")
                    }
                    let original = dry[outputSlot][channel * frameSize + index]
                    writeChannels[channel][index] = original + wet * (clean - original)
                }
            }
            if outputCount > 0 {
                writeBuffer.frameLength = AVAudioFrameCount(outputCount)
                try output!.write(from: writeBuffer)
                written += Int64(outputCount)
            }
        }
        try Task.checkCancellation()
        guard written == input.length else {
            throw DerivedMediaError.exportFailed("Шумоподавление создало неполную звуковую дорожку")
        }
        output = nil
        completed = true
    }
}
