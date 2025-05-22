import Foundation

/// Helper for encoding and decoding full file paths using Base64
struct FilenameMapper {
    /// Encode a full file path to Base64
    static func encodePath(_ path: String) -> String {
        Data(path.utf8).base64EncodedString()
    }
    /// Decode a Base64-encoded path
    static func decodePath(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
} 