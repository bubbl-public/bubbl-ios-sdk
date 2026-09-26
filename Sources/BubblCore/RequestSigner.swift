#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Signs device API v1 requests the way the backend verifies them (bubbl's
/// `App\Services\Api\ApiRequestSigner`): the hex HMAC-SHA256, keyed with the install's secret,
/// of `METHOD \n path \n canonical query \n timestamp \n body`. The contract's signing vectors
/// (contracts/v1/fixtures/v1/signing.json) pin every step, and RequestSignerContractTests
/// checks this file against them. CryptoKit on Apple platforms; swift-crypto (the same API)
/// where the core is built elsewhere.
package enum RequestSigner {
    /// The X-Bubbl-Signature value. `path` has no leading slash ("api/v1/config"), `query` holds
    /// the decoded values as they appear in the URL, and `body` is the exact bytes sent (empty
    /// for a GET), since the server signs the raw body it receives.
    package static func sign(secret: String, method: String, path: String, timestamp: Int, body: String, query: [String: String] = [:]) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let message = Data(stringToSign(method: method, path: path, timestamp: timestamp, body: body, query: query).utf8)

        return HMAC<SHA256>.authenticationCode(for: message, using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// What gets signed: the five parts joined by newlines, the method upper-cased.
    package static func stringToSign(method: String, path: String, timestamp: Int, body: String, query: [String: String] = [:]) -> String {
        [method.uppercased(), path, canonicalQuery(query), String(timestamp), body].joined(separator: "\n")
    }

    /// The query parameters sorted by name and RFC 3986-encoded (a space is %20, not +; only
    /// A–Z a–z 0–9 - . _ ~ are left as they are), so the order they were sent in doesn't matter.
    /// The SDK only sends flat, lower-case ASCII names, for which sorting by code point matches
    /// the server's ksort().
    package static func canonicalQuery(_ query: [String: String]) -> String {
        query.keys.sorted()
            .map { "\(encode($0))=\(encode(query[$0] ?? ""))" }
            .joined(separator: "&")
    }

    /// RFC 3986 percent-encoding of a string's UTF-8 bytes, hex in upper case (PHP's rawurlencode).
    private static func encode(_ value: String) -> String {
        var encoded = ""
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                encoded.append(Character(UnicodeScalar(byte)))
            default:
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }
}
