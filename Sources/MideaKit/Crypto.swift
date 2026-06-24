import CommonCrypto
import CryptoKit
import Foundation

/// Low-level cryptographic primitives used by the Midea LAN protocol.
///
/// Ported from `msmart`'s Security class. AES-CBC (no padding) and AES-ECB
/// (PKCS7) are not exposed by CryptoKit, so they go through CommonCrypto.
enum Crypto {
  static func md5(_ data: [UInt8]) -> [UInt8] {
    var hasher = Insecure.MD5()
    hasher.update(data: Data(data))
    return Array(hasher.finalize())
  }

  static func sha256(_ data: [UInt8]) -> [UInt8] {
    Array(SHA256.hash(data: Data(data)))
  }

  static func xor(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
    precondition(lhs.count == rhs.count, "xor operands must be equal length")
    return zip(lhs, rhs).map { $0 ^ $1 }
  }

  enum CryptoError: Error {
    case operationFailed(status: Int32)
  }

  private static func aes(
    operation: Int,
    options: Int,
    key: [UInt8],
    iv: [UInt8],
    input: [UInt8]
  ) throws -> [UInt8] {
    var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
    var outputCount = 0
    let status = CCCrypt(
      CCOperation(operation),
      CCAlgorithm(kCCAlgorithmAES),
      CCOptions(options),
      key, key.count,
      iv,
      input, input.count,
      &output, output.count,
      &outputCount
    )
    guard status == kCCSuccess else {
      throw CryptoError.operationFailed(status: status)
    }
    return Array(output.prefix(outputCount))
  }

  /// AES-CBC with a zero IV and no padding (input must be block-aligned).
  static func encryptCBC(key: [UInt8], _ input: [UInt8]) throws -> [UInt8] {
    try aes(
      operation: kCCEncrypt, options: 0,
      key: key, iv: [UInt8](repeating: 0, count: 16), input: input
    )
  }

  static func decryptCBC(key: [UInt8], _ input: [UInt8]) throws -> [UInt8] {
    try aes(
      operation: kCCDecrypt, options: 0,
      key: key, iv: [UInt8](repeating: 0, count: 16), input: input
    )
  }

  /// AES-ECB with PKCS7 padding.
  static func encryptECB(key: [UInt8], _ input: [UInt8]) throws -> [UInt8] {
    try aes(
      operation: kCCEncrypt, options: kCCOptionECBMode | kCCOptionPKCS7Padding,
      key: key, iv: [UInt8](repeating: 0, count: 16), input: input
    )
  }

  static func decryptECB(key: [UInt8], _ input: [UInt8]) throws -> [UInt8] {
    try aes(
      operation: kCCDecrypt, options: kCCOptionECBMode | kCCOptionPKCS7Padding,
      key: key, iv: [UInt8](repeating: 0, count: 16), input: input
    )
  }
}
