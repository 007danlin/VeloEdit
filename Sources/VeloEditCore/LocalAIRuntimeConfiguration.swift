import Foundation

/// A private scheduler prevents unrelated local AI clients from evicting the
/// verifier and its reusable image prefixes. Model files remain shared on disk.
public enum LocalAIRuntimeConfiguration {
    public static let baseURL = URL(string: "http://127.0.0.1:\(port(in: ProcessInfo.processInfo.environment))")!

    // Isolated local profiles can exercise first installation while another
    // VeloEdit runtime serves the user's projects on its normal port.
    private static func port(in environment: [String: String]) -> UInt16 {
        guard let raw = environment["VELOEDIT_OLLAMA_PORT"], let port = UInt16(raw), port >= 1024 else { return 11435 }
        return port
    }

    static func promptCacheMiB(physicalMemory: UInt64) -> Int {
        max(512, min(4096, Int(physicalMemory / (16 * 1_048_576))))
    }

    static func serverEnvironment(inherited: [String: String], physicalMemory: UInt64) -> [String: String] {
        var environment = inherited
        environment["OLLAMA_HOST"] = "127.0.0.1:\(port(in: inherited))"
        environment["OLLAMA_MAX_LOADED_MODELS"] = "1"
        environment["OLLAMA_NUM_PARALLEL"] = "1"
        environment["OLLAMA_CONTEXT_LENGTH"] = "32768"
        environment["LLAMA_ARG_CACHE_RAM"] = String(promptCacheMiB(physicalMemory: physicalMemory))
        environment["OLLAMA_FLASH_ATTENTION"] = "1"
        // A user's unrelated Ollama configuration must not quantize this
        // verifier's cache. Runtime upgrades retain FP16 and the same weights.
        environment["OLLAMA_KV_CACHE_TYPE"] = "f16"
        return environment
    }
}
