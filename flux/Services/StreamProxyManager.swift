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
        
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener?.port?.rawValue {
                        self?.port = port
                    }
                    self?.isRunning = true
                    print("[StreamProxy] Proxy server listening on http://127.0.0.1:\(self?.port ?? 51547)")
                case .failed(let error):
                    print("[StreamProxy] Server failed: \(error)")
                    self?.isRunning = false
                default:
                    break
                }
            }
            
            listener?.start(queue: DispatchQueue(label: "StreamProxy", qos: .userInitiated))
        } catch {
            print("[StreamProxy] Failed to create listener: \(error)")
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
    
    /// Creates a proxy URL that MPV can play. The proxy will fetch `originalURL` with the given `headers`.
    func proxyURL(for originalURL: URL, headers: [String: String]) -> URL? {
        guard let headersJSON = encodeHeaders(headers) else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/proxy"
        components.queryItems = [
            URLQueryItem(name: "url", value: originalURL.absoluteString),
            URLQueryItem(name: "headers", value: headersJSON)
        ]
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
        
        // Extract Range header from the incoming request
        var rangeHeader: String? = nil
        for line in lines {
            if line.lowercased().hasPrefix("range:") {
                rangeHeader = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }
        
        // Parse query parameters from the path
        guard let urlComponents = URLComponents(string: "http://localhost\(fullPath)"),
              let queryItems = urlComponents.queryItems else {
            sendError(connection, status: 400, message: "Missing query parameters")
            return
        }
        
        guard let targetURLString = queryItems.first(where: { $0.name == "url" })?.value,
              let targetURL = URL(string: targetURLString) else {
            sendError(connection, status: 400, message: "Missing or invalid 'url' parameter")
            return
        }
        
        let headersString = queryItems.first(where: { $0.name == "headers" })?.value
        let customHeaders = decodeHeaders(headersString)
        
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
        
        // Handle HEAD requests
        if method == "HEAD" {
            let config = URLSessionConfiguration.default
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
        let config = URLSessionConfiguration.default
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
    private static let highWaterMark = 2 * 1024 * 1024
    private static let lowWaterMark = 1 * 1024 * 1024

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

    init(id: UUID, connection: NWConnection, configuration: URLSessionConfiguration, onComplete: @escaping (UUID) -> Void) {
        self.id = id
        self.connection = connection
        self.onComplete = onComplete
        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func start(request: URLRequest) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish(cancelConnection: false)
            default:
                break
            }
        }

        task = session?.dataTask(with: request)
        task?.resume()
    }

    func cancel() {
        finish(cancelConnection: true)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            sendError(status: 502, message: "Invalid upstream response")
            completionHandler(.cancel)
            return
        }

        let headerData = makeResponseHeaders(from: httpResponse).data(using: .utf8)
        didSendResponseHeaders = true
        if let headerData {
            enqueue(headerData, from: dataTask)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !didSendResponseHeaders {
            sendError(status: 502, message: "Upstream response missing headers")
            return
        }
        enqueue(data, from: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, !isCompleted {
            print("[StreamProxy] Upstream stream ended with error: \(error.localizedDescription)")
            if !didSendResponseHeaders {
                sendError(status: 502, message: "Upstream error: \(error.localizedDescription)")
                return
            }
        }

        finish(cancelConnection: true)
    }

    private func makeResponseHeaders(from httpResponse: HTTPURLResponse) -> String {
        let statusCode = httpResponse.statusCode
        var responseHeaders = "HTTP/1.1 \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode))\r\n"
        responseHeaders += "Access-Control-Allow-Origin: *\r\n"
        responseHeaders += "Accept-Ranges: bytes\r\n"

        let headersToCopy = ["Content-Length", "Content-Type", "Content-Range", "ETag", "Last-Modified"]
        for headerName in headersToCopy {
            if let value = httpResponse.value(forHTTPHeaderField: headerName) {
                responseHeaders += "\(headerName): \(value)\r\n"
            }
        }

        if httpResponse.value(forHTTPHeaderField: "Content-Type") == nil {
            responseHeaders += "Content-Type: application/octet-stream\r\n"
        }

        responseHeaders += "\r\n"
        return responseHeaders
    }

    /// Bounded, completion-driven delivery. URLSession may read upstream data
    /// considerably faster than mpv drains the loopback socket; suspending the
    /// upstream task prevents an unbounded queue of Data buffers in that case.
    private func enqueue(_ data: Data, from dataTask: URLSessionDataTask) {
        var shouldSuspend = false
        stateLock.lock()
        if !isCompleted {
            queuedBytes += data.count
            if !upstreamSuspended && queuedBytes >= Self.highWaterMark {
                upstreamSuspended = true
                shouldSuspend = true
            }
        }
        let completed = isCompleted
        stateLock.unlock()

        guard !completed else { return }
        if shouldSuspend {
            #if DEBUG
            print("[StreamProxy] Pausing upstream at \(queuedBytes / 1024) KB queued")
            #endif
            dataTask.suspend()
        }

        sendQueue.async { [weak self] in
            guard let self, !self.isCompleted else { return }
            self.pendingSends.append(data)
            self.sendNextIfNeeded()
        }
    }

    private func sendNextIfNeeded() {
        dispatchPrecondition(condition: .onQueue(sendQueue))
        guard !isCompleted, !isSending, !pendingSends.isEmpty else { return }
        isSending = true
        let data = pendingSends.removeFirst()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.sendQueue.async {
                self.isSending = false
                self.completeSend(byteCount: data.count)
                if let error {
                    print("[StreamProxy] Client send failed: \(error)")
                    self.finish(cancelConnection: false)
                    return
                }
                self.sendNextIfNeeded()
            }
        })
    }

    private func completeSend(byteCount: Int) {
        var taskToResume: URLSessionDataTask?
        stateLock.lock()
        queuedBytes = max(0, queuedBytes - byteCount)
        if upstreamSuspended, queuedBytes <= Self.lowWaterMark, !isCompleted {
            upstreamSuspended = false
            taskToResume = task
        }
        stateLock.unlock()
        taskToResume?.resume()
    }

    private func sendError(status: Int, message: String) {
        let body = "{\"error\":\"\(message)\"}"
        let response = "HTTP/1.1 \(status) Error\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n\(body)"
        guard let data = response.data(using: .utf8) else {
            finish(cancelConnection: true)
            return
        }

        sendQueue.async { [weak self] in
            guard let self, !self.isCompleted else { return }
            self.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.finish(cancelConnection: true)
            })
        }
    }

    private func finish(cancelConnection: Bool) {
        stateLock.lock()
        guard !isCompleted else {
            stateLock.unlock()
            return
        }
        isCompleted = true
        queuedBytes = 0
        upstreamSuspended = false
        let task = task
        let session = session
        stateLock.unlock()

        task?.cancel()
        session?.invalidateAndCancel()
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.pendingSends.removeAll(keepingCapacity: false)
            self.isSending = false
            self.session = nil
            if cancelConnection {
                self.connection.cancel()
            }
            self.onComplete(self.id)
        }
    }
}
