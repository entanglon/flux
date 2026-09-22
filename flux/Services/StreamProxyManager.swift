import OSLog
import Foundation
import Network

/// A lightweight local HTTP proxy server that injects custom headers (Referer, User-Agent, etc.)
/// for streams that require them. This is equivalent to Stremio's `server.js` proxy functionality.
///
/// Usage:
/// 1. Start the proxy: `StreamProxyManager.shared.start()`
/// 2. Get a proxy URL: `StreamProxyManager.shared.proxyURL(for: originalURL, headers: ["Referer": "..."])`
/// 3. MPV plays the proxy URL → proxy fetches the real stream with correct headers → pipes bytes to MPV
class StreamProxyManager {
    static let shared = StreamProxyManager()
    
    private var listener: NWListener?
    private(set) var port: UInt16 = 51547
    private(set) var isRunning = false
    private let activePipesLock = NSLock()
    private var activePipes: [UUID: StreamProxyDataPipe] = [:]
    
    private init() {}
    
    // MARK: - Public API
    
    func start() {
        guard !isRunning else { return }
        startListener(preferredPort: port)
    }

    private func startListener(preferredPort: UInt16) {
        do {
            let params = NWParameters.tcp
            // Security: Strictly bind to loopback interface (never expose proxy to external LAN/Wi-Fi)
            params.requiredInterfaceType = .loopback
            let newListener: NWListener
            if preferredPort == 0 {
                newListener = try NWListener(using: params)
            } else if let p = NWEndpoint.Port(rawValue: preferredPort) {
                newListener = try NWListener(using: params, on: p)
            } else {
                newListener = try NWListener(using: params)
            }
            self.listener = newListener
            
            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    if let port = self.listener?.port?.rawValue {
                        self.port = port
                    }
                    self.isRunning = true
                    print("[StreamProxy] Proxy server listening on http://127.0.0.1:\(self.port)")
                case .failed(let error):
                    print("[StreamProxy] Server failed on port \(preferredPort): \(error)")
                    self.isRunning = false
                    self.listener?.cancel()
                    self.listener = nil
                    // Port fallback resilience: If preferred port is busy, fallback to next port or dynamic port
                    if preferredPort >= 51547 && preferredPort < 51560 {
                        let nextPort = preferredPort + 1
                        print("[StreamProxy] Retrying on fallback port \(nextPort)...")
                        self.startListener(preferredPort: nextPort)
                    } else if preferredPort != 0 {
                        print("[StreamProxy] Retrying on system-assigned dynamic loopback port...")
                        self.startListener(preferredPort: 0)
                    }
                default:
                    break
                }
            }
            
            newListener.start(queue: DispatchQueue(label: "StreamProxy", qos: .userInitiated))
        } catch {
            print("[StreamProxy] Failed to create listener on port \(preferredPort): \(error)")
            if preferredPort >= 51547 && preferredPort < 51560 {
                startListener(preferredPort: preferredPort + 1)
            } else if preferredPort != 0 {
                startListener(preferredPort: 0)
            }
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false

        activePipesLock.lock()
        let pipes = Array(activePipes.values)
        activePipes.removeAll()
        activePipesLock.unlock()
        pipes.forEach { $0.cancel() }
    }
    
    /// Creates a proxy URL that MPV can play. The proxy will fetch `originalURL` with optional `headers`.
    func proxyURL(for originalURL: URL, headers: [String: String]? = nil, title: String? = nil) -> URL? {
        var items = [
            URLQueryItem(name: "url", value: originalURL.absoluteString)
        ]
        if let headers = headers, !headers.isEmpty, let headersJSON = encodeHeaders(headers) {
            items.append(URLQueryItem(name: "headers", value: headersJSON))
        }
        if let title = title, !title.isEmpty {
            items.append(URLQueryItem(name: "title", value: title))
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/proxy"
        components.queryItems = items
        return components.url
    }
    
    // MARK: - Connection Handling
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "StreamProxyConnection", qos: .userInitiated))
        
        // Read the HTTP request
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let data = data, error == nil else {
                connection.cancel()
                return
            }
            
            guard let requestString = String(data: data, encoding: .utf8) else {
                self?.sendError(connection, status: 400, message: "Bad Request")
                return
            }
            
            self?.processRequest(connection, requestString: requestString)
        }
    }
    
    private func processRequest(_ connection: NWConnection, requestString: String) {
        // Parse the HTTP request line to get the path
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendError(connection, status: 400, message: "Bad Request")
            return
        }
        
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendError(connection, status: 400, message: "Bad Request")
            return
        }
        
        let method = parts[0]
        let fullPath = parts[1]
        
        // Extract incoming headers that need forwarding (like Range)
        var rangeHeader: String?
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let headerParts = line.components(separatedBy: ": ")
            if headerParts.count >= 2 {
                let key = headerParts[0].lowercased()
                let value = headerParts.dropFirst().joined(separator: ": ")
                if key == "range" {
                    rangeHeader = value
                }
            }
        }
        
        // Parse query parameters from the path
        guard let urlComponents = URLComponents(string: "http://localhost\(fullPath)"),
              let queryItems = urlComponents.queryItems else {
            sendError(connection, status: 400, message: "Missing query parameters")
            return
        }
        
        guard let targetURLString = queryItems.first(where: { $0.name == "url" })?.value,
              let targetURL = URL(string: targetURLString),
              let scheme = targetURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            sendError(connection, status: 400, message: "Missing or invalid 'url' parameter (only HTTP and HTTPS supported)")
            return
        }

        // Security: Disallow loopback destinations to prevent SSRF against internal services
        let host = (targetURL.host ?? "").lowercased()
        guard host != "127.0.0.1", host != "localhost", host != "::1" else {
            sendError(connection, status: 403, message: "Loopback targets forbidden")
            return
        }
        
        let headersString = queryItems.first(where: { $0.name == "headers" })?.value
        let customHeaders = decodeHeaders(headersString)
        let streamTitle = queryItems.first(where: { $0.name == "title" })?.value
        
        print("[StreamProxy] \(method) -> \(targetURL.host ?? "?") [\(customHeaders.keys.joined(separator: ", "))]")
        
        // Build the upstream request with custom headers
        var request = URLRequest(url: targetURL)
        request.httpMethod = method
        request.timeoutInterval = 30
        
        // Set custom headers from the addon's behaviorHints
        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        // Forward the Range header for seeking support
        if let range = rangeHeader {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        
        // Set a default User-Agent if not provided
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        }
        
        let isProxyTarget: Bool = {
            if StreamRouteProxyManager.shared.shouldProxy(url: targetURL, title: streamTitle) {
                return true
            }
            // If StreamRouteProxy is enabled, any direct HTTP stream passing through
            // StreamProxyManager is by definition a web-scraped stream with custom headers (e.g. PenguPlay, 2peckle).
            // Unless it is a local host or metadata provider, route it through the proxy.
            if StreamRouteProxyManager.shared.isEnabled {
                let host = (targetURL.host ?? "").lowercased()
                let bypass = host == "127.0.0.1" || host == "localhost" || host.contains("pocketbase") || host.contains("cinemeta") || host.contains("themoviedb")
                return !bypass
            }
            return false
        }()

        // Handle HEAD requests
        if method == "HEAD" {
            let config: URLSessionConfiguration
            if isProxyTarget,
               let proxyDict = StreamRouteProxyManager.shared.proxyDictionary() {
                config = URLSessionConfiguration.ephemeral
                config.connectionProxyDictionary = proxyDict
            } else {
                config = URLSessionConfiguration.default
            }
            config.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: config)
            
            let task = session.dataTask(with: request) { [weak self] _, response, error in
                if let httpResponse = response as? HTTPURLResponse {
                    let statusCode = httpResponse.statusCode
                    var headers = "HTTP/1.1 \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode))\r\n"
                    headers += "Accept-Ranges: bytes\r\n"
                    if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length") {
                        headers += "Content-Length: \(contentLength)\r\n"
                    }
                    if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
                        headers += "Content-Type: \(contentType)\r\n"
                    }
                    if let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range") {
                        headers += "Content-Range: \(contentRange)\r\n"
                    }
                    headers += "Access-Control-Allow-Origin: *\r\n"
                    headers += "\r\n"
                    connection.send(content: headers.data(using: .utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                } else {
                    self?.sendError(connection, status: 502, message: "Upstream error: \(error?.localizedDescription ?? "unknown")")
                }
            }
            task.resume()
            return
        }
        
        // Handle GET requests by piping upstream chunks directly to MPV.
        let config: URLSessionConfiguration
        if isProxyTarget,
           let proxyDict = StreamRouteProxyManager.shared.proxyDictionary() {
            config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = proxyDict
            Logger.player.info("[StreamProxy] Routing upstream fetch for \(targetURL.host ?? "", privacy: .public) through forward proxy")
            print("[StreamProxy] Routing upstream fetch for \(targetURL.host ?? "") through forward proxy")
        } else {
            config = URLSessionConfiguration.default
        }
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 0 // No resource timeout for streaming
        let id = UUID()
        let pipe = StreamProxyDataPipe(id: id, connection: connection, configuration: config) { [weak self] completedID in
            self?.removePipe(id: completedID)
        }
        storePipe(pipe, id: id)
        pipe.start(request: request)
    }
    
    // MARK: - Helpers

    private func storePipe(_ pipe: StreamProxyDataPipe, id: UUID) {
        activePipesLock.lock()
        activePipes[id] = pipe
        activePipesLock.unlock()
    }

    private func removePipe(id: UUID) {
        activePipesLock.lock()
        activePipes[id] = nil
        activePipesLock.unlock()
    }
    
    private func sendError(_ connection: NWConnection, status: Int, message: String) {
        let body = "{\"error\":\"\(message)\"}"
        let response = "HTTP/1.1 \(status) Error\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func encodeHeaders(_ headers: [String: String]) -> String? {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: headers),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return nil }
        return jsonString
    }
    
    private func decodeHeaders(_ encoded: String?) -> [String: String] {
        guard let encoded = encoded else {
            return [:]
        }

        let candidates = [encoded, encoded.removingPercentEncoding].compactMap { $0 }
        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                return json
            }
        }
        return [:]
    }
}

private final class StreamProxyDataPipe: NSObject, URLSessionDataDelegate {
    private static let highWaterMark = 16 * 1024 * 1024
    private static let lowWaterMark = 4 * 1024 * 1024

    private let id: UUID
    private let connection: NWConnection
    private let onComplete: (UUID) -> Void
    private let sendQueue = DispatchQueue(label: "StreamProxyDataPipe.send", qos: .userInitiated)
    private let stateLock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var didSendResponseHeaders = false
    private var isCompleted = false
    private var pendingSends: [Data] = []
    private var isSending = false
    /// Includes the item currently being sent plus every item awaiting a local
    /// socket completion. This is the actual memory budget for the pipe.
    private var queuedBytes = 0
    private var upstreamSuspended = false
    // MARK: - Transparent resume state (mid-stream upstream blips must not kill downstream)
    /// Media byte offset this pipe started at (parsed from the initial Range, else 0).
    private var baseOffset: Int64 = 0
    /// Template upstream request (URL + custom headers + UA) reused for silent retries.
    private var initialUpstreamRequest: URLRequest?
    /// Cumulative MEDIA bytes fully sent downstream (excludes response headers).
    private var totalForwardedBytes: Int64 = 0
    /// Byte length of the downstream response headers (excluded from resume math).
    private var responseHeaderLength = 0
    /// Attempt bookkeeping: expected/delivered body bytes for the CURRENT upstream attempt.
    private var attemptIndex = 0
    private var attemptExpectedBytes: Int64?
    private var attemptDeliveredBytes: Int64 = 0
    /// True while a retry response (not the initial one) is expected.
    private var expectingRetryResponse = false
    /// Silent-retry budget per connection (then legacy finish → mpv reconnects itself).
    private var upstreamRetryCount = 0
    private let maxUpstreamRetries = 3
    private let retryBackoffs: [TimeInterval] = [0.05, 0.2, 0.5]
    private var pendingRetry: DispatchWorkItem?
    /// Set when a retry was requested mid-send; launch runs after the in-flight
    /// send completes so resume offsets stay exact (no gaps, no duplicates).
    private var retryDeferredUntilSendCompletes = false

    init(id: UUID, connection: NWConnection, configuration: URLSessionConfiguration, onComplete: @escaping (UUID) -> Void) {
        self.id = id
        self.connection = connection
        self.onComplete = onComplete
        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func start(request: URLRequest) {
        stateLock.lock()
        self.initialUpstreamRequest = request
        if let rangeHeader = request.value(forHTTPHeaderField: "Range"),
           let parsed = Self.parseRangeStart(from: rangeHeader) {
            self.baseOffset = parsed
        }
        self.attemptExpectedBytes = nil
        self.attemptDeliveredBytes = 0
        self.attemptIndex = 0
        stateLock.unlock()

        let task = session?.dataTask(with: request)
        self.task = task
        task?.resume()
    }

    func cancel() {
        stateLock.lock()
        isCompleted = true
        pendingRetry?.cancel()
        pendingRetry = nil
        stateLock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        connection.cancel()
    }

    private static func parseRangeStart(from rangeHeader: String) -> Int64? {
        guard rangeHeader.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = String(rangeHeader.dropFirst("bytes=".count))
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let start = Int64(first.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return start
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        stateLock.lock()
        guard !isCompleted else {
            stateLock.unlock()
            completionHandler(.cancel)
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            stateLock.unlock()
            completionHandler(.cancel)
            return
        }

        let isRetry = expectingRetryResponse
        expectingRetryResponse = false
        attemptDeliveredBytes = 0
        if httpResponse.expectedContentLength > 0 {
            attemptExpectedBytes = httpResponse.expectedContentLength
        } else {
            attemptExpectedBytes = nil
        }

        if isRetry {
            guard httpResponse.statusCode == 206 else {
                stateLock.unlock()
                completionHandler(.cancel)
                finish(error: NSError(domain: "StreamProxy", code: httpResponse.statusCode,
                                     userInfo: [NSLocalizedDescriptionKey: "Retry returned non-206 (\(httpResponse.statusCode))"]))
                return
            }
            stateLock.unlock()
            completionHandler(.allow)
            return
        }

        guard !didSendResponseHeaders else {
            stateLock.unlock()
            completionHandler(.allow)
            return
        }
        didSendResponseHeaders = true

        let statusCode = httpResponse.statusCode
        var headerString = "HTTP/1.1 \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode))\r\n"
        for (key, value) in httpResponse.allHeaderFields {
            let keyStr = "\(key)"
            let lower = keyStr.lowercased()
            if lower == "connection" || lower == "transfer-encoding" { continue }
            headerString += "\(keyStr): \(value)\r\n"
        }
        if httpResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil {
            headerString += "Access-Control-Allow-Origin: *\r\n"
        }
        headerString += "Connection: close\r\n\r\n"
        stateLock.unlock()

        if let headerData = headerString.data(using: .utf8) {
            stateLock.lock()
            responseHeaderLength = headerData.count
            stateLock.unlock()
            enqueue(data: headerData, isMediaBody: false)
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stateLock.lock()
        guard !isCompleted else {
            stateLock.unlock()
            return
        }
        attemptDeliveredBytes += Int64(data.count)
        stateLock.unlock()

        enqueue(data: data, isMediaBody: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateLock.lock()
        guard !isCompleted else {
            stateLock.unlock()
            return
        }

        if let error = error, (error as NSError).code == NSURLErrorCancelled {
            stateLock.unlock()
            return
        }

        let isPrematureEOF: Bool
        if let error = error {
            let code = (error as NSError).code
            let isNetworkBlip = code == NSURLErrorNetworkConnectionLost
                || code == NSURLErrorTimedOut
                || code == NSURLErrorCannotConnectToHost
                || (error as NSError).domain == NSPOSIXErrorDomain && code == 54 // ECONNRESET
            isPrematureEOF = isNetworkBlip
        } else if let expected = attemptExpectedBytes, attemptDeliveredBytes < expected {
            isPrematureEOF = true
        } else {
            isPrematureEOF = false
        }

        if isPrematureEOF && upstreamRetryCount < maxUpstreamRetries && initialUpstreamRequest != nil {
            upstreamRetryCount += 1
            let retryIndex = upstreamRetryCount
            let backoff = retryBackoffs[min(retryIndex - 1, retryBackoffs.count - 1)]

            if isSending {
                retryDeferredUntilSendCompletes = true
                stateLock.unlock()
                return
            }

            stateLock.unlock()
            scheduleRetry(after: backoff)
            return
        }

        stateLock.unlock()
        finish(error: error)
    }

    private func scheduleRetry(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            guard !self.isCompleted, let baseRequest = self.initialUpstreamRequest else {
                self.stateLock.unlock()
                return
            }

            let resumeOffset = self.baseOffset + self.totalForwardedBytes
            var retryReq = baseRequest
            retryReq.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
            self.expectingRetryResponse = true
            self.attemptIndex += 1
            self.attemptExpectedBytes = nil
            self.attemptDeliveredBytes = 0
            self.task = nil
            self.stateLock.unlock()

            let nextTask = self.session?.dataTask(with: retryReq)
            self.stateLock.lock()
            self.task = nextTask
            self.stateLock.unlock()
            nextTask?.resume()
        }

        stateLock.lock()
        pendingRetry = work
        stateLock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func enqueue(data: Data, isMediaBody: Bool) {
        stateLock.lock()
        pendingSends.append(data)
        queuedBytes += data.count

        if queuedBytes >= Self.highWaterMark && !upstreamSuspended {
            upstreamSuspended = true
            task?.suspend()
        }

        let shouldStartSending = !isSending
        if shouldStartSending {
            isSending = true
        }
        stateLock.unlock()

        if shouldStartSending {
            sendNext()
        }
    }

    private func sendNext() {
        sendQueue.async { [weak self] in
            guard let self = self else { return }

            self.stateLock.lock()
            guard !self.isCompleted, !self.pendingSends.isEmpty else {
                self.isSending = false
                let needRetry = self.retryDeferredUntilSendCompletes
                self.retryDeferredUntilSendCompletes = false
                self.stateLock.unlock()

                if needRetry {
                    self.scheduleRetry(after: 0.0)
                }
                return
            }

            let chunk = self.pendingSends.removeFirst()
            self.stateLock.unlock()

            self.connection.send(content: chunk, completion: .contentProcessed { [weak self] sendError in
                guard let self = self else { return }

                if let sendError = sendError {
                    self.finish(error: sendError)
                    return
                }

                self.stateLock.lock()
                self.queuedBytes -= chunk.count
                self.totalForwardedBytes += Int64(chunk.count)

                if self.upstreamSuspended && self.queuedBytes <= Self.lowWaterMark {
                    self.upstreamSuspended = false
                    self.task?.resume()
                }
                self.stateLock.unlock()

                self.sendNext()
            })
        }
    }

    private func finish(error: Error?) {
        stateLock.lock()
        guard !isCompleted else {
            stateLock.unlock()
            return
        }
        isCompleted = true
        pendingRetry?.cancel()
        pendingRetry = nil
        let drainRemaining = pendingSends
        pendingSends.removeAll()
        queuedBytes = 0
        stateLock.unlock()

        task?.cancel()
        session?.finishTasksAndInvalidate()

        if !drainRemaining.isEmpty {
            var combined = Data()
            drainRemaining.forEach { combined.append($0) }
            connection.send(content: combined, isComplete: true, completion: .contentProcessed { [weak self] _ in
                guard let self = self else { return }
                self.connection.cancel()
                self.onComplete(self.id)
            })
        } else {
            connection.cancel()
            onComplete(id)
        }
    }
}
