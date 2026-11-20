//
//  REST.swift
//
//  A deliberately tiny HTTP surface. Four endpoints, no more.
//
//  Every REST call is a fresh TLS handshake unless the connection is reused,
//  and a handshake measured at about 5.4 KB. That is 20 heartbeats' worth of
//  data for one request. So:
//
//    * History is fetched only when a conversation opens, and only when the
//      disk cache cannot already satisfy it.
//    * Nothing is prefetched. Ever.
//    * limit=25, not the default 50.
//    * One URLSession is kept alive so HTTP keep-alive can amortise the
//      handshake across calls.
//
//  iOS 12: no async/await, so these are completion handlers.
//

import Foundation

public final class REST {

    public enum RESTError: Error, CustomStringConvertible {
        case notAuthenticated
        case http(Int, String)
        case transport(Error)
        case malformed

        public var description: String {
            switch self {
            case .notAuthenticated:  return "not signed in"
            case .http(let c, let m): return "HTTP \(c): \(m)"
            case .transport(let e):  return "network error: \(e.localizedDescription)"
            case .malformed:         return "unexpected response"
            }
        }
    }

    private static let base = "https://discord.com/api/v10"

    private let token: String
    private let meter: ByteMeter
    private let session: URLSession

    public init(token: String, meter: ByteMeter) {
        self.token = token
        self.meter = meter

        let config = URLSessionConfiguration.default
        // No disk cache: a cached avatar or embed is a byte we already paid
        // for, and we never request them in the first place.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "Authorization": token,
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 12_5_7 like Mac OS X) "
                        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            "Accept": "application/json",
            "Accept-Language": "en-US,en;q=0.9",
            // Ask for compression explicitly. Discord honours it and message
            // JSON compresses well.
            "Accept-Encoding": "gzip, deflate",
        ]
        session = URLSession(configuration: config)
    }

    // MARK: - Endpoints

    /// The DM channel list. Needed only when READY did not carry it.
    public func fetchDMChannels(completion: @escaping (Result<[GatewayEvent.DMChannel], RESTError>) -> Void) {
        request("GET", "/users/@me/channels") { result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let json):
                guard let array = json as? [[String: Any]] else {
                    completion(.failure(.malformed)); return
                }
                var channels = [GatewayEvent.DMChannel]()
                for raw in array {
                    guard let id = raw["id"] as? String else { continue }
                    let type = (raw["type"] as? Int) ?? -1
                    guard type == 1 || type == 3 else { continue }
                    var recipients = [String]()
                    if let objs = raw["recipients"] as? [[String: Any]] {
                        recipients = objs.compactMap { $0["id"] as? String }
                    }
                    channels.append(GatewayEvent.DMChannel(
                        id: id,
                        type: type,
                        recipientIDs: recipients,
                        lastMessageID: raw["last_message_id"] as? String,
                        name: raw["name"] as? String))
                }
                completion(.success(channels))
            }
        }
    }

    /// Message history. Called on conversation open, never speculatively.
    ///
    /// - Parameter before: paginate backwards for scrollback.
    public func fetchMessages(channelID: String,
                              limit: Int = 25,
                              before: String? = nil,
                              completion: @escaping (Result<[[String: Any]], RESTError>) -> Void) {
        var path = "/channels/\(channelID)/messages?limit=\(limit)"
        if let before = before { path += "&before=\(before)" }
        request("GET", path) { result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let json):
                guard let array = json as? [[String: Any]] else {
                    completion(.failure(.malformed)); return
                }
                completion(.success(array))
            }
        }
    }

    public func sendMessage(channelID: String,
                            content: String,
                            completion: @escaping (Result<[String: Any], RESTError>) -> Void) {
        // A nonce lets us match the echoed MESSAGE_CREATE to our own send and
        // replace the optimistic row instead of showing it twice.
        let nonce = String(Int(Date().timeIntervalSince1970 * 1000))
        let body: [String: Any] = ["content": content, "nonce": nonce, "tts": false]
        request("POST", "/channels/\(channelID)/messages", body: body) { result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let json):
                guard let dict = json as? [String: Any] else {
                    completion(.failure(.malformed)); return
                }
                completion(.success(dict))
            }
        }
    }

    /// Mark read. Small, and it stops the unread badge drifting from reality.
    public func ack(channelID: String, messageID: String,
                    completion: ((Result<Void, RESTError>) -> Void)? = nil) {
        request("POST", "/channels/\(channelID)/messages/\(messageID)/ack",
                body: ["token": NSNull()]) { result in
            switch result {
            case .failure(let e): completion?(.failure(e))
            case .success:        completion?(.success(()))
            }
        }
    }

    // MARK: - Plumbing

    private func request(_ method: String,
                         _ path: String,
                         body: [String: Any]? = nil,
                         completion: @escaping (Result<Any, RESTError>) -> Void) {
        guard let url = URL(string: REST.base + path) else {
            completion(.failure(.malformed)); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        var sentBytes = 0
        if let body = body {
            let data = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data()
            req.httpBody = data
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            sentBytes = data.count
        }
        // Rough header cost. Counted so REST traffic shows up in the meter
        // rather than hiding behind the gateway figure.
        meter.recordOutbound(frameBytes: sentBytes + 350)

        session.dataTask(with: req) { [weak self] data, response, error in
            if let error = error {
                completion(.failure(.transport(error))); return
            }
            let bytes = data?.count ?? 0
            self?.meter.recordInbound(frameBytes: bytes + 250, inflated: bytes)

            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.malformed)); return
            }
            guard (200..<300).contains(http.statusCode) else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                // 401 means the token is dead. Say so plainly; do not echo it.
                completion(.failure(.http(http.statusCode, String(text.prefix(200)))))
                return
            }
            if http.statusCode == 204 || (data?.isEmpty ?? true) {
                completion(.success([String: Any]())); return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
                completion(.failure(.malformed)); return
            }
            completion(.success(json))
        }.resume()
    }
}
