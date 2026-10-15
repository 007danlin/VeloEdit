import Foundation

public enum SpeechRuntimeSelection {
    // Include the engine in cache keys: moving a project between ARM and Intel
    // must not mix chunks produced by different models/alignment methods.
    public static var identifier: String {
        #if arch(x86_64)
        return "whisper.cpp-1.8.3-cpu-q5_0-v1"
        #else
        return "whisperkit-f4e5d6b-coreml-v4"
        #endif
    }
}
