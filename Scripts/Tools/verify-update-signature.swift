import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let publicBytes = Data(base64Encoded: arguments[2]),
      let signature = Data(base64Encoded: arguments[3]) else {
    throw CocoaError(.fileReadCorruptFile)
}
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe)
guard publicKey.isValidSignature(signature, for: archive) else {
    FileHandle.standardError.write(Data("Invalid Sparkle update signature\n".utf8))
    exit(1)
}
