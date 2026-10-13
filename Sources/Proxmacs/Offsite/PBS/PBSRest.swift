import CryptoKit
import Foundation

/// Plain PBS REST API (HTTP/1.1) with API-token auth and optional certificate pinning.
struct PBSRest {
    let settings: PBSSettings
    let secret: String

    func get(_ path: String, query: [(String, String)] = []) async throws -> Any? {
        try await perform(method: "GET", path: path + PBSH2Session.encodeQuery(query), body: nil)
    }

    func post(_ path: String, form: [(String, String)]) async throws -> Any? {
        let body = String(PBSH2Session.encodeQuery(form).dropFirst())
        return try await perform(method: "POST", path: path, body: Data(body.utf8))
    }

    private func perform(method: String, path: String, body: Data?) async throws -> Any? {
        guard let url = URL(string: "https://\(settings.host):\(settings.port)\(path)") else {
            throw ProxmacsError("Invalid PBS URL for \(settings.host)")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("PBSAPIToken \(settings.authId):\(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }

        let delegate = PinnedTrustDelegate(fingerprint: settings.fingerprint.map(PBSFingerprint.normalize))
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw PBSHTTPError(status: status, body: String(decoding: data, as: UTF8.self)) }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return (object as? [String: Any])?["data"]
    }
}

private final class PinnedTrustDelegate: NSObject, URLSessionDelegate {
    let fingerprint: String?

    init(fingerprint: String?) { self.fingerprint = fingerprint }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, let fingerprint else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let actual = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        if actual == fingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
