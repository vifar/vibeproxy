import Foundation
import Network

/**
 A lightweight HTTP proxy that intercepts requests to add extended thinking parameters
 for Claude models based on model name suffixes.
 
 Model name pattern:
 - `*-thinking-NUMBER` → Custom token budget (e.g., claude-sonnet-4-5-20250929-thinking-5000)
 
 The proxy strips the suffix and adds the `thinking` parameter to the request body
 before forwarding to CLIProxyAPI.
 
 Examples:
 - claude-sonnet-4-5-20250929-thinking-2000 → 2,000 token budget
 - claude-sonnet-4-5-20250929-thinking-8000 → 8,000 token budget
 */
struct VercelGatewayConfig {
    var enabled: Bool
    var apiKey: String

    var isActive: Bool { enabled && !apiKey.isEmpty }
}

class ThinkingProxy {
    private var listener: NWListener?
    let proxyPort: UInt16 = 8317
    private let targetPort: UInt16 = 8318
    private let targetHost = "127.0.0.1"
    private(set) var isRunning = false
    private let stateQueue = DispatchQueue(label: "io.automaze.vibeproxy.thinking-proxy-state")

    var vercelConfig = VercelGatewayConfig(enabled: false, apiKey: "")

    /// Ordered list of providers to try on each request. First entry is always `.primary`.
    var fallbackChain: [FallbackProvider] = [.defaultPrimary]
    
    private enum Config {
        static let hardTokenCap = 32000
        static let minimumHeadroom = 1024
        static let headroomRatio = 0.1
        static let vercelGatewayHost = "ai-gateway.vercel.sh"
        static let anthropicVersion = "2023-06-01"
    }
    
    /**
     Starts the thinking proxy server on port 8317
     */
    func start() {
        guard !isRunning else {
            NSLog("[ThinkingProxy] Already running")
            return
        }
        
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            
            guard let port = NWEndpoint.Port(rawValue: proxyPort) else {
                NSLog("[ThinkingProxy] Invalid port: %d", proxyPort)
                return
            }
            listener = try NWListener(using: parameters, on: port)
            
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    DispatchQueue.main.async {
                        self?.isRunning = true
                    }
                    NSLog("[ThinkingProxy] Listening on port \(self?.proxyPort ?? 0)")
                case .failed(let error):
                    NSLog("[ThinkingProxy] Failed: \(error)")
                    DispatchQueue.main.async {
                        self?.isRunning = false
                    }
                case .cancelled:
                    NSLog("[ThinkingProxy] Cancelled")
                    DispatchQueue.main.async {
                        self?.isRunning = false
                    }
                default:
                    break
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.start(queue: .global(qos: .userInitiated))
            
        } catch {
            NSLog("[ThinkingProxy] Failed to start: \(error)")
        }
    }
    
    /**
     Stops the thinking proxy server
     */
    func stop() {
        stateQueue.sync {
            guard isRunning else { return }
            
            listener?.cancel()
            listener = nil
            DispatchQueue.main.async { [weak self] in
                self?.isRunning = false
            }
            NSLog("[ThinkingProxy] Stopped")
        }
    }
    
    /**
     Handles an incoming connection from a client
     */
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(from: connection)
    }
    
    /**
     Receives the HTTP request from the client
     Accumulates data until full request is received (handles large payloads)
     */
    private func receiveRequest(from connection: NWConnection, accumulatedData: Data = Data()) {
        // Start the iterative receive loop
        receiveNextChunk(from: connection, accumulatedData: accumulatedData)
    }
    
    /**
     Receives request data iteratively (uses async scheduling instead of recursion to avoid stack buildup)
     */
    private func receiveNextChunk(from connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1048576) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[ThinkingProxy] Receive error: \(error)")
                connection.cancel()
                return
            }
            
            guard let data = data, !data.isEmpty else {
                if isComplete {
                    connection.cancel()
                }
                return
            }
            
            var newAccumulatedData = accumulatedData
            newAccumulatedData.append(data)
            
            // Check if we have a complete HTTP request
            if let requestString = String(data: newAccumulatedData, encoding: .utf8),
               let headerEndRange = requestString.range(of: "\r\n\r\n") {
                
                // Extract Content-Length if present
                let headerEndIndex = requestString.distance(from: requestString.startIndex, to: headerEndRange.upperBound)
                let headerPart = String(requestString.prefix(headerEndIndex))
                
                if let contentLengthLine = headerPart.components(separatedBy: "\r\n").first(where: { $0.lowercased().starts(with: "content-length:") }) {
                    let contentLengthStr = contentLengthLine.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)
                    if let contentLength = Int(contentLengthStr) {
                        let bodyStartIndex = headerEndIndex
                        let currentBodyLength = newAccumulatedData.count - bodyStartIndex
                        
                        // If we haven't received the full body yet, schedule next iteration
                        if currentBodyLength < contentLength {
                            self.receiveNextChunk(from: connection, accumulatedData: newAccumulatedData)
                            return
                        }
                    }
                }
                
                // We have a complete request, process it
                self.processRequest(data: newAccumulatedData, connection: connection)
            } else if !isComplete {
                // Haven't found header end yet, schedule next iteration
                self.receiveNextChunk(from: connection, accumulatedData: newAccumulatedData)
            } else {
                // Complete but malformed, process what we have
                self.processRequest(data: newAccumulatedData, connection: connection)
            }
        }
    }
    
    /**
     Processes the HTTP request, modifies it if needed, and forwards to CLIProxyAPI
     */
    private func processRequest(data: Data, connection: NWConnection) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendError(to: connection, statusCode: 400, message: "Invalid request")
            return
        }
        
        // Parse HTTP request
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendError(to: connection, statusCode: 400, message: "Invalid request line")
            return
        }
        
        // Extract method, path, and HTTP version
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 3 else {
            sendError(to: connection, statusCode: 400, message: "Invalid request format")
            return
        }
        
        let method = parts[0]
        let path = parts[1]
        let httpVersion = parts[2]
        NSLog("[ThinkingProxy] Incoming request: \(method) \(path)")

        // Collect headers while preserving original casing
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            let valueStart = line.index(after: separatorIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        
        // Find the body start
        guard let bodyStartRange = requestString.range(of: "\r\n\r\n") else {
            NSLog("[ThinkingProxy] Error: Could not find body separator in request")
            sendError(to: connection, statusCode: 400, message: "Invalid request format - no body separator")
            return
        }
        
        let bodyStart = requestString.distance(from: requestString.startIndex, to: bodyStartRange.upperBound)
        let bodyString = String(requestString[requestString.index(requestString.startIndex, offsetBy: bodyStart)...])
        
        // Redirect Amp CLI login directly to ampcode.com to preserve auth state cookies
        if path.starts(with: "/auth/cli-login") || path.starts(with: "/api/auth/cli-login") {
            let loginPath = path.hasPrefix("/api/") ? String(path.dropFirst(4)) : path
            let redirectUrl = "https://ampcode.com" + loginPath
            NSLog("[ThinkingProxy] Redirecting Amp CLI login to: \(redirectUrl)")
            sendRedirect(to: connection, location: redirectUrl)
            return
        }

        // Rewrite Amp CLI paths
        var rewrittenPath = path
        if path.starts(with: "/provider/") {
            // Rewrite /provider/* to /api/provider/*
            rewrittenPath = "/api" + path
            NSLog("[ThinkingProxy] Rewriting Amp provider path: \(path) -> \(rewrittenPath)")
        }
        
        // Check if this is an Amp management request (anything not targeting provider or /v1)
        // Note: /provider/ paths are already rewritten to /api/provider/ above
        let isProviderPath = rewrittenPath.starts(with: "/api/provider/")
        let isCliProxyPath = rewrittenPath.starts(with: "/v1/") || rewrittenPath.starts(with: "/api/v1/")
        if !isProviderPath && !isCliProxyPath {
            let ampPath = rewrittenPath
            NSLog("[ThinkingProxy] Amp management request detected, forwarding to ampcode.com: \(ampPath)")
            forwardToAmp(method: method, path: ampPath, version: httpVersion, headers: headers, body: bodyString, originalConnection: connection)
            return
        }
        
        // Try to parse and modify JSON body for POST requests
        var modifiedBody = bodyString
        var thinkingEnabled = false
        var matchedCopilotAlias = false
        
        if method == "POST" && !bodyString.isEmpty {
            let aliasRewrite = ModelAliasMapper.rewriteModelIfAlias(in: bodyString)
            modifiedBody = aliasRewrite.body
            matchedCopilotAlias = aliasRewrite.matchedAlias

            if let result = processThinkingParameter(jsonString: modifiedBody) {
                modifiedBody = result.0
                thinkingEnabled = result.1
            }
            // Strip cache_control fields that cause 400 errors via the OAuth route
            if let stripped = stripCacheControl(from: modifiedBody) {
                modifiedBody = stripped
            }
        }
        
        // Route Claude requests through Vercel AI Gateway when configured
        if vercelConfig.isActive && method == "POST" && isClaudeModelRequest(body: modifiedBody) && !matchedCopilotAlias {
            NSLog("[ThinkingProxy] Routing Claude request via Vercel AI Gateway")
            forwardToVercel(method: method, path: "/v1/messages", version: httpVersion, headers: headers, body: modifiedBody, thinkingEnabled: thinkingEnabled, originalConnection: connection)
            return
        }
        
        forwardWithFallback(method: method, path: rewrittenPath, version: httpVersion,
                            headers: headers, body: modifiedBody, thinkingEnabled: thinkingEnabled,
                            originalConnection: connection, providerIndex: 0)
    }
    
    private func isClaudeModelRequest(body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? String else { return false }
        return model.starts(with: "claude-") || model.starts(with: "gemini-claude-")
    }

    /// Strips `cache_control` fields from the request body that cause 400 errors via the OAuth route
    private func stripCacheControl(from jsonString: String) -> String? {
        guard let jsonData = jsonString.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        var modified = false

        func stripFromDictArray(_ array: inout [[String: Any]]) {
            for i in array.indices {
                if array[i]["cache_control"] != nil {
                    array[i].removeValue(forKey: "cache_control")
                    modified = true
                }
                // Recurse into nested content arrays
                if var nested = array[i]["content"] as? [[String: Any]] {
                    stripFromDictArray(&nested)
                    array[i]["content"] = nested
                }
            }
        }

        if var system = json["system"] as? [[String: Any]] {
            stripFromDictArray(&system)
            if modified { json["system"] = system }
        }

        if var messages = json["messages"] as? [[String: Any]] {
            stripFromDictArray(&messages)
            if modified { json["messages"] = messages }
        }

        if var tools = json["tools"] as? [[String: Any]] {
            stripFromDictArray(&tools)
            if modified { json["tools"] = tools }
        }

        guard modified else { return nil }

        guard let modifiedData = try? JSONSerialization.data(withJSONObject: json),
              let modifiedString = String(data: modifiedData, encoding: .utf8) else {
            return nil
        }

        NSLog("[ThinkingProxy] Stripped cache_control fields from request body")
        return modifiedString
    }
    
    /**
     Processes the JSON body to add thinking parameter if model name has a thinking suffix
     Returns tuple of (modifiedJSON, needsTransformation)
     */
    private func processThinkingParameter(jsonString: String) -> (String, Bool)? {
        guard let jsonData = jsonString.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let model = json["model"] as? String else {
            return nil
        }
        
        // Only process Claude models (including gemini-claude variants)
        guard model.starts(with: "claude-") || model.starts(with: "gemini-claude-") else {
            return (jsonString, false)  // Not Claude, pass through
        }
        
        // Check for thinking suffix pattern: -thinking-NUMBER
        let thinkingPrefix = "-thinking-"
        if let thinkingRange = model.range(of: thinkingPrefix, options: .backwards),
           thinkingRange.upperBound < model.endIndex {
            
            // Extract the number after "-thinking-"
            let budgetString = String(model[thinkingRange.upperBound...])
            
            // For gemini-claude-* models, preserve "-thinking" and only strip the number
            // e.g. gemini-claude-opus-4-5-thinking-10000 -> gemini-claude-opus-4-5-thinking
            // For claude-* models, strip the entire suffix
            // e.g. claude-opus-4-5-20251101-thinking-10000 -> claude-opus-4-5-20251101
            let cleanModel: String
            if model.starts(with: "gemini-claude-") {
                cleanModel = String(model[..<thinkingRange.upperBound].dropLast(1))  // Keep "-thinking", drop trailing "-"
            } else {
                cleanModel = String(model[..<thinkingRange.lowerBound])
            }
            json["model"] = cleanModel
            
            // Only add thinking parameter if it's a valid integer
            if let budget = Int(budgetString), budget > 0 {
                let effectiveBudget = min(budget, Config.hardTokenCap - 1)
                if effectiveBudget != budget {
                    NSLog("[ThinkingProxy] Adjusted thinking budget from \(budget) to \(effectiveBudget) to stay within limits")
                }

                // Claude Opus 4.6+ requires adaptive thinking; older models use enabled+budget_tokens
                let isAdaptiveModel = cleanModel.contains("opus-4-6") || cleanModel.contains("opus-4-7")
                if isAdaptiveModel {
                    json["thinking"] = ["type": "adaptive"]
                    NSLog("[ThinkingProxy] Using adaptive thinking for model '\(cleanModel)'")
                } else {
                    json["thinking"] = [
                        "type": "enabled",
                        "budget_tokens": effectiveBudget
                    ]
                }
                
                // Ensure max token limits are greater than the thinking budget
                // Claude requires: max_output_tokens (or legacy max_tokens) > thinking.budget_tokens
                // (only relevant for non-adaptive models, but safe to set for all)
                let tokenHeadroom = max(Config.minimumHeadroom, Int(Double(effectiveBudget) * Config.headroomRatio))
                let desiredMaxTokens = effectiveBudget + tokenHeadroom
                var requiredMaxTokens = min(desiredMaxTokens, Config.hardTokenCap)
                if requiredMaxTokens <= effectiveBudget {
                    requiredMaxTokens = min(effectiveBudget + 1, Config.hardTokenCap)
                }
                
                let hasMaxOutputTokensField = json.keys.contains("max_output_tokens")
                var adjusted = false
                
                if let currentMaxTokens = json["max_tokens"] as? Int {
                    if currentMaxTokens <= effectiveBudget {
                        json["max_tokens"] = requiredMaxTokens
                    }
                    adjusted = true
                }
                
                if let currentMaxOutputTokens = json["max_output_tokens"] as? Int {
                    if currentMaxOutputTokens <= effectiveBudget {
                        json["max_output_tokens"] = requiredMaxTokens
                    }
                    adjusted = true
                }
                
                if !adjusted {
                    if hasMaxOutputTokensField {
                        json["max_output_tokens"] = requiredMaxTokens
                    } else {
                        json["max_tokens"] = requiredMaxTokens
                    }
                }
                
                NSLog("[ThinkingProxy] Transformed model '\(model)' → '\(cleanModel)' with thinking budget \(effectiveBudget)")
            } else {
                // Invalid number - just strip suffix and use vanilla model
                NSLog("[ThinkingProxy] Stripped invalid thinking suffix from '\(model)' → '\(cleanModel)' (no thinking)")
            }
            
            // Convert back to JSON
            if let modifiedData = try? JSONSerialization.data(withJSONObject: json),
               let modifiedString = String(data: modifiedData, encoding: .utf8) {
                return (modifiedString, true)
            }
        } else if model.hasSuffix("-thinking") || model.contains("-thinking(") {
            // Model ends with -thinking or uses -thinking(budget) syntax (e.g. gemini-claude-opus-4-5-thinking, gemini-claude-opus-4-5-thinking(32768))
            // Enable beta header but don't modify body - let backend handle thinking budget
            NSLog("[ThinkingProxy] Detected thinking model '\(model)' - enabling beta header, passing through to backend")
            return (jsonString, true)
        }
        
        return (jsonString, false)  // No transformation needed
    }
    
    /**
     Forwards Amp API requests to ampcode.com, stripping the /api/ prefix
     */
    private func forwardToAmp(method: String, path: String, version: String, headers: [(String, String)], body: String, originalConnection: NWConnection) {
        // Create TLS parameters for HTTPS
        let tlsOptions = NWProtocolTLS.Options()
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        
        // Create connection to ampcode.com:443
        let endpoint = NWEndpoint.hostPort(host: "ampcode.com", port: 443)
        let targetConnection = NWConnection(to: endpoint, using: parameters)
        
        targetConnection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Build the forwarded request
                var forwardedRequest = "\(method) \(path) \(version)\r\n"
                
                // Forward most headers, excluding some that need to be overridden
                let excludedHeaders: Set<String> = ["host", "content-length", "connection", "transfer-encoding"]
                for (name, value) in headers {
                    if !excludedHeaders.contains(name.lowercased()) {
                        forwardedRequest += "\(name): \(value)\r\n"
                    }
                }
                
                // Override Host header for ampcode.com
                forwardedRequest += "Host: ampcode.com\r\n"
                forwardedRequest += "Connection: close\r\n"
                
                let contentLength = body.utf8.count
                forwardedRequest += "Content-Length: \(contentLength)\r\n"
                forwardedRequest += "\r\n"
                forwardedRequest += body
                
                // Send to ampcode.com
                if let requestData = forwardedRequest.data(using: .utf8) {
                    targetConnection.send(content: requestData, completion: .contentProcessed({ error in
                        if let error = error {
                            NSLog("[ThinkingProxy] Send error to ampcode.com: \(error)")
                            targetConnection.cancel()
                            originalConnection.cancel()
                        } else {
                            // Receive response from ampcode.com and rewrite Location headers
                            self.receiveAmpResponse(from: targetConnection, originalConnection: originalConnection)
                        }
                    }))
                }
                
            case .failed(let error):
                NSLog("[ThinkingProxy] Connection to ampcode.com failed: \(error)")
                self.sendError(to: originalConnection, statusCode: 502, message: "Bad Gateway - Could not connect to ampcode.com")
                targetConnection.cancel()
                
            default:
                break
            }
        }
        
        targetConnection.start(queue: .global(qos: .userInitiated))
    }
    
    /**
     Receives response from ampcode.com and rewrites Location headers to add /api/ prefix
     */
    private func receiveAmpResponse(from targetConnection: NWConnection, originalConnection: NWConnection) {
        targetConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[ThinkingProxy] Receive Amp response error: \(error)")
                targetConnection.cancel()
                originalConnection.cancel()
                return
            }
            
            if let data = data, !data.isEmpty {
                // Convert to string to rewrite headers
                if var responseString = String(data: data, encoding: .utf8) {
                    // Rewrite Location headers to prepend /api/
                    responseString = responseString.replacingOccurrences(
                        of: "\r\nlocation: /",
                        with: "\r\nlocation: /api/",
                        options: .caseInsensitive
                    )
                    responseString = responseString.replacingOccurrences(
                        of: "\r\nLocation: /",
                        with: "\r\nLocation: /api/"
                    )

                    // Rewrite absolute Location headers to keep browser on localhost proxy
                    responseString = responseString.replacingOccurrences(
                        of: "\r\nLocation: https://ampcode.com/",
                        with: "\r\nLocation: /api/",
                        options: .caseInsensitive
                    )
                    responseString = responseString.replacingOccurrences(
                        of: "\r\nLocation: http://ampcode.com/",
                        with: "\r\nLocation: /api/",
                        options: .caseInsensitive
                    )

                    // Rewrite cookie domain so browser accepts cookies from localhost
                    responseString = responseString.replacingOccurrences(
                        of: "Domain=.ampcode.com",
                        with: "Domain=localhost",
                        options: .caseInsensitive
                    )
                    responseString = responseString.replacingOccurrences(
                        of: "Domain=ampcode.com",
                        with: "Domain=localhost",
                        options: .caseInsensitive
                    )
                    
                    if let modifiedData = responseString.data(using: .utf8) {
                        originalConnection.send(content: modifiedData, completion: .contentProcessed({ sendError in
                            if let sendError = sendError {
                                NSLog("[ThinkingProxy] Send Amp response error: \(sendError)")
                            }
                            
                            if isComplete {
                                targetConnection.cancel()
                                originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                                    originalConnection.cancel()
                                }))
                            } else {
                                // Continue receiving more data
                                self.receiveAmpResponse(from: targetConnection, originalConnection: originalConnection)
                            }
                        }))
                    }
                } else {
                    // Not UTF-8, forward as-is
                    originalConnection.send(content: data, completion: .contentProcessed({ sendError in
                        if let sendError = sendError {
                            NSLog("[ThinkingProxy] Send Amp response error: \(sendError)")
                        }
                        
                        if isComplete {
                            targetConnection.cancel()
                            originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                                originalConnection.cancel()
                            }))
                        } else {
                            self.receiveAmpResponse(from: targetConnection, originalConnection: originalConnection)
                        }
                    }))
                }
            } else if isComplete {
                targetConnection.cancel()
                originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                    originalConnection.cancel()
                }))
            }
        }
    }
    
    /**
     Forwards Claude requests to Vercel AI Gateway (ai-gateway.vercel.sh)
     */
    private func forwardToVercel(method: String, path: String, version: String, headers: [(String, String)], body: String, thinkingEnabled: Bool, originalConnection: NWConnection) {
        let tlsOptions = NWProtocolTLS.Options()
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(Config.vercelGatewayHost), port: 443)
        let targetConnection = NWConnection(to: endpoint, using: parameters)
        let apiKey = vercelConfig.apiKey
        
        targetConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                var forwardedRequest = "\(method) \(path) \(version)\r\n"
                
                let excludedHeaders: Set<String> = ["host", "content-length", "connection", "transfer-encoding", "authorization", "x-api-key"]
                var existingBetaHeader: String? = nil
                
                for (name, value) in headers {
                    let lower = name.lowercased()
                    if excludedHeaders.contains(lower) { continue }
                    if lower == "anthropic-beta" {
                        existingBetaHeader = value
                        continue
                    }
                    forwardedRequest += "\(name): \(value)\r\n"
                }
                
                // Vercel auth
                forwardedRequest += "x-api-key: \(apiKey)\r\n"
                forwardedRequest += "anthropic-version: \(Config.anthropicVersion)\r\n"
                forwardedRequest += "content-type: application/json\r\n"
                
                // Thinking beta header
                if thinkingEnabled {
                    var betaValue = BetaHeaders.interleavedThinking
                    if let existing = existingBetaHeader, !existing.contains(BetaHeaders.interleavedThinking) {
                        betaValue = "\(existing),\(BetaHeaders.interleavedThinking)"
                    }
                    forwardedRequest += "anthropic-beta: \(betaValue)\r\n"
                } else if let existing = existingBetaHeader {
                    forwardedRequest += "anthropic-beta: \(existing)\r\n"
                }
                
                forwardedRequest += "Host: \(Config.vercelGatewayHost)\r\n"
                forwardedRequest += "Connection: close\r\n"
                
                let contentLength = body.utf8.count
                forwardedRequest += "Content-Length: \(contentLength)\r\n"
                forwardedRequest += "\r\n"
                forwardedRequest += body
                
                if let requestData = forwardedRequest.data(using: .utf8) {
                    targetConnection.send(content: requestData, completion: .contentProcessed({ error in
                        if let error = error {
                            NSLog("[ThinkingProxy] Vercel send error: \(error)")
                            targetConnection.cancel()
                            originalConnection.cancel()
                        } else {
                            self.receiveResponse(from: targetConnection, originalConnection: originalConnection)
                        }
                    }))
                }
                
            case .failed(let error):
                NSLog("[ThinkingProxy] Vercel connection failed: \(error)")
                self.sendError(to: originalConnection, statusCode: 502, message: "Bad Gateway - Could not connect to Vercel AI Gateway")
                targetConnection.cancel()
                
            default:
                break
            }
        }
        
        targetConnection.start(queue: .global(qos: .userInitiated))
    }
    
    private enum BetaHeaders {
        static let interleavedThinking = "interleaved-thinking-2025-05-14"
    }

    // MARK: - Fallback Chain

    /// Entry point: tries each provider in `fallbackChain` in order, advancing on retriable errors.
    private func forwardWithFallback(
        method: String, path: String, version: String,
        headers: [(String, String)], body: String,
        thinkingEnabled: Bool,
        originalConnection: NWConnection,
        providerIndex: Int
    ) {
        guard providerIndex < fallbackChain.count else {
            NSLog("[ThinkingProxy] All \(fallbackChain.count) provider(s) failed — returning 502")
            sendError(to: originalConnection, statusCode: 502, message: "All providers failed")
            return
        }
        let provider = fallbackChain[providerIndex]
        NSLog("[ThinkingProxy] Trying provider[\(providerIndex)] (\(provider.label))")

        switch provider.kind {
        case .primary:
            forwardToPrimaryWithFallback(
                method: method, path: path, version: version,
                headers: headers, body: body, thinkingEnabled: thinkingEnabled,
                originalConnection: originalConnection, providerIndex: providerIndex
            )
        case .ollama, .openaiCompatible:
            forwardDirectWithFallback(
                provider: provider,
                method: method, path: path, version: version,
                headers: headers, body: body,
                originalConnection: originalConnection, providerIndex: providerIndex
            )
        }
    }

    /// Forwards to cli-proxy-api-plus (port 8318) with fallback-aware response checking.
    private func forwardToPrimaryWithFallback(
        method: String, path: String, version: String,
        headers: [(String, String)], body: String,
        thinkingEnabled: Bool,
        originalConnection: NWConnection,
        providerIndex: Int,
        retryWithApiPrefix: Bool = true
    ) {
        guard let port = NWEndpoint.Port(rawValue: targetPort) else {
            forwardWithFallback(method: method, path: path, version: version,
                                headers: headers, body: body, thinkingEnabled: thinkingEnabled,
                                originalConnection: originalConnection, providerIndex: providerIndex + 1)
            return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(targetHost), port: port)
        let targetConn = NWConnection(to: endpoint, using: NWParameters.tcp)

        targetConn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let requestData = self.buildPrimaryRequestData(
                    method: method, path: path, version: version,
                    headers: headers, body: body, thinkingEnabled: thinkingEnabled
                )
                targetConn.send(content: requestData, completion: .contentProcessed { error in
                    if let error = error {
                        NSLog("[ThinkingProxy] Primary send error: \(error); trying next provider")
                        targetConn.cancel()
                        self.forwardWithFallback(method: method, path: path, version: version,
                                                 headers: headers, body: body, thinkingEnabled: thinkingEnabled,
                                                 originalConnection: originalConnection, providerIndex: providerIndex + 1)
                    } else {
                        self.receiveResponseWithFallbackCheck(
                            from: targetConn, originalConnection: originalConnection,
                            method: method, path: path, version: version,
                            headers: headers, body: body, thinkingEnabled: thinkingEnabled,
                            providerIndex: providerIndex, retryWithApiPrefix: retryWithApiPrefix
                        )
                    }
                })
            case .failed(let error):
                NSLog("[ThinkingProxy] Primary connection failed: \(error); trying next provider")
                targetConn.cancel()
                self.forwardWithFallback(method: method, path: path, version: version,
                                         headers: headers, body: body, thinkingEnabled: thinkingEnabled,
                                         originalConnection: originalConnection, providerIndex: providerIndex + 1)
            default: break
            }
        }
        targetConn.start(queue: .global(qos: .userInitiated))
    }

    /// Forwards directly to an Ollama or OpenAI-compatible provider with fallback-aware response checking.
    private func forwardDirectWithFallback(
        provider: FallbackProvider,
        method: String, path: String, version: String,
        headers: [(String, String)], body: String,
        originalConnection: NWConnection,
        providerIndex: Int
    ) {
        let tryNext = { [weak self] in
            guard let self else { return }
            self.forwardWithFallback(method: method, path: path, version: version,
                                     headers: headers, body: body, thinkingEnabled: false,
                                     originalConnection: originalConnection, providerIndex: providerIndex + 1)
        }

        guard let baseURLString = provider.baseURL,
              let baseURL = URL(string: baseURLString) else {
            NSLog("[ThinkingProxy] Provider[\(providerIndex)] has no valid base URL; skipping")
            tryNext(); return
        }

        let host = baseURL.host ?? "localhost"
        let isHTTPS = baseURL.scheme?.lowercased() == "https"
        let defaultPort: UInt16 = isHTTPS ? 443 : 80
        let portNumber = UInt16(baseURL.port ?? Int(defaultPort))
        guard let nwPort = NWEndpoint.Port(rawValue: portNumber) else {
            NSLog("[ThinkingProxy] Provider[\(providerIndex)] invalid port; skipping")
            tryNext(); return
        }

        let parameters: NWParameters = isHTTPS
            ? NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
            : NWParameters.tcp

        // Substitute fallback model into request body if configured
        var effectiveBody = body
        if let fallbackModel = provider.fallbackModel, !fallbackModel.isEmpty,
           let rewritten = rewriteModel(in: body, to: fallbackModel) {
            NSLog("[ThinkingProxy] Provider[\(providerIndex)] substituting model → \(fallbackModel)")
            effectiveBody = rewritten
        }

        // Map the inbound /v1/... path onto the provider's base path
        let basePath = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
        let effectivePath: String
        if path.starts(with: "/v1/") || path.starts(with: "/api/v1/") {
            let stripped = path.starts(with: "/api/v1/") ? String(path.dropFirst(4)) : path
            effectivePath = basePath.isEmpty ? stripped : basePath + stripped
        } else {
            effectivePath = basePath.isEmpty ? "/v1/chat/completions" : basePath + "/chat/completions"
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let targetConn = NWConnection(to: endpoint, using: parameters)

        targetConn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let requestData = self.buildDirectRequestData(
                    method: method, path: effectivePath, version: version,
                    headers: headers, body: effectiveBody,
                    host: host, apiKey: provider.apiKey
                )
                targetConn.send(content: requestData, completion: .contentProcessed { error in
                    if let error = error {
                        NSLog("[ThinkingProxy] Direct send error to [\(providerIndex)]: \(error); trying next")
                        targetConn.cancel(); tryNext()
                    } else {
                        self.receiveResponseWithFallbackCheck(
                            from: targetConn, originalConnection: originalConnection,
                            method: method, path: path, version: version,
                            headers: headers, body: body, thinkingEnabled: false,
                            providerIndex: providerIndex, retryWithApiPrefix: false
                        )
                    }
                })
            case .failed(let error):
                NSLog("[ThinkingProxy] Direct connection to provider[\(providerIndex)] failed: \(error); trying next")
                targetConn.cancel(); tryNext()
            default: break
            }
        }
        targetConn.start(queue: .global(qos: .userInitiated))
    }

    /// Reads the first chunk from a provider, inspects the HTTP status, and either
    /// falls back to the next provider or streams the response to the client.
    private func receiveResponseWithFallbackCheck(
        from targetConn: NWConnection,
        originalConnection: NWConnection,
        method: String, path: String, version: String,
        headers: [(String, String)], body: String,
        thinkingEnabled: Bool,
        providerIndex: Int,
        retryWithApiPrefix: Bool
    ) {
        targetConn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error = error {
                NSLog("[ThinkingProxy] Receive error from provider[\(providerIndex)]: \(error); trying next")
                targetConn.cancel()
                self.forwardWithFallback(method: method, path: path, version: version,
                                         headers: headers, body: body, thinkingEnabled: thinkingEnabled,
                                         originalConnection: originalConnection, providerIndex: providerIndex + 1)
                return
            }

            guard let data, !data.isEmpty else {
                if isComplete {
                    NSLog("[ThinkingProxy] Empty response from provider[\(providerIndex)]; trying next")
                    targetConn.cancel()
                    self.forwardWithFallback(method: method, path: path, version: version,
                                             headers: headers, body: body, thinkingEnabled: thinkingEnabled,
                                             originalConnection: originalConnection, providerIndex: providerIndex + 1)
                }
                return
            }

            let snippet = String(data: data, encoding: .utf8) ?? ""

            // 404 path-normalisation retry (primary only)
            if retryWithApiPrefix && providerIndex == 0 {
                let is404 = snippet.contains("HTTP/1.1 404") || snippet.contains("HTTP/1.0 404")
                             || snippet.contains("404 page not found")
                if is404, !path.starts(with: "/api/"), !path.starts(with: "/v1/") {
                    NSLog("[ThinkingProxy] 404 from primary for \(path); retrying with /api prefix")
                    targetConn.cancel()
                    self.forwardToPrimaryWithFallback(
                        method: method, path: "/api" + path, version: version,
                        headers: headers, body: body, thinkingEnabled: thinkingEnabled,
                        originalConnection: originalConnection, providerIndex: providerIndex,
                        retryWithApiPrefix: false
                    )
                    return
                }
            }

            // Fallback trigger check
            let httpStatus = self.parseHTTPStatus(from: snippet)
            let shouldFallback: Bool
            if let status = httpStatus {
                shouldFallback = FallbackTrigger.shouldFallback(httpStatus: status)
                               || FallbackTrigger.shouldFallback(onBodySnippet: snippet)
            } else {
                shouldFallback = FallbackTrigger.shouldFallback(onBodySnippet: snippet)
            }

            if shouldFallback && providerIndex + 1 < self.fallbackChain.count {
                let statusStr = httpStatus.map { "\($0)" } ?? "unknown"
                NSLog("[ThinkingProxy] HTTP \(statusStr) from provider[\(providerIndex)] (\(self.fallbackChain[providerIndex].label)); falling back to [\(providerIndex + 1)]")
                targetConn.cancel()
                self.forwardWithFallback(method: method, path: path, version: version,
                                         headers: headers, body: body, thinkingEnabled: thinkingEnabled,
                                         originalConnection: originalConnection, providerIndex: providerIndex + 1)
                return
            }

            // No fallback — forward the already-received first chunk, then stream the rest
            originalConnection.send(content: data, completion: .contentProcessed { sendError in
                if let sendError = sendError {
                    NSLog("[ThinkingProxy] Send response error: \(sendError)")
                }
                if isComplete {
                    targetConn.cancel()
                    originalConnection.send(content: nil, isComplete: true,
                                            completion: .contentProcessed { _ in originalConnection.cancel() })
                } else {
                    self.streamNextChunk(from: targetConn, to: originalConnection)
                }
            })
        }
    }

    // MARK: - Request builders

    private func buildPrimaryRequestData(
        method: String, path: String, version: String,
        headers: [(String, String)], body: String,
        thinkingEnabled: Bool
    ) -> Data {
        var request = "\(method) \(path) \(version)\r\n"
        let excluded: Set<String> = ["content-length", "host", "transfer-encoding"]
        var existingBeta: String?
        for (name, value) in headers {
            let lower = name.lowercased()
            if excluded.contains(lower) { continue }
            if lower == "anthropic-beta" { existingBeta = value; continue }
            request += "\(name): \(value)\r\n"
        }
        if thinkingEnabled {
            let betaValue: String
            if let existing = existingBeta, !existing.contains(BetaHeaders.interleavedThinking) {
                betaValue = "\(existing),\(BetaHeaders.interleavedThinking)"
            } else {
                betaValue = existingBeta ?? BetaHeaders.interleavedThinking
            }
            request += "anthropic-beta: \(betaValue)\r\n"
        } else if let existing = existingBeta {
            request += "anthropic-beta: \(existing)\r\n"
        }
        request += "Host: \(targetHost):\(targetPort)\r\n"
        request += "Connection: close\r\n"
        request += "Content-Length: \(body.utf8.count)\r\n\r\n"
        request += body
        return request.data(using: .utf8) ?? Data()
    }

    private func buildDirectRequestData(
        method: String, path: String, version: String,
        headers: [(String, String)], body: String,
        host: String, apiKey: String?
    ) -> Data {
        var request = "\(method) \(path) \(version)\r\n"
        let excluded: Set<String> = ["host", "content-length", "connection", "transfer-encoding",
                                     "authorization", "x-api-key"]
        for (name, value) in headers {
            if excluded.contains(name.lowercased()) { continue }
            request += "\(name): \(value)\r\n"
        }
        if let key = apiKey, !key.isEmpty {
            request += "Authorization: Bearer \(key)\r\n"
        }
        request += "Host: \(host)\r\n"
        request += "Connection: close\r\n"
        request += "Content-Type: application/json\r\n"
        request += "Content-Length: \(body.utf8.count)\r\n\r\n"
        request += body
        return request.data(using: .utf8) ?? Data()
    }

    // MARK: - Helpers

    /// Parses the HTTP status code from the first line of an HTTP response snippet.
    private func parseHTTPStatus(from snippet: String) -> Int? {
        guard snippet.hasPrefix("HTTP/") else { return nil }
        let line = snippet.components(separatedBy: "\r\n").first ?? ""
        let parts = line.components(separatedBy: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        return status
    }

    /// Rewrites the `model` field in a JSON request body string.
    private func rewriteModel(in jsonString: String, to model: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        json["model"] = model
        guard let out = try? JSONSerialization.data(withJSONObject: json),
              let result = String(data: out, encoding: .utf8) else { return nil }
        return result
    }

    /**
     Receives response from a target connection.
     Starts the streaming loop for response data.
     */
    private func receiveResponse(from targetConnection: NWConnection, originalConnection: NWConnection) {
        streamNextChunk(from: targetConnection, to: originalConnection)
    }
    
    /**
     Streams response chunks iteratively (uses async scheduling instead of recursion to avoid stack buildup)
     */
    private func streamNextChunk(from targetConnection: NWConnection, to originalConnection: NWConnection) {
        targetConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[ThinkingProxy] Receive response error: \(error)")
                targetConnection.cancel()
                originalConnection.cancel()
                return
            }
            
            if let data = data, !data.isEmpty {
                // Forward response chunk to original client
                originalConnection.send(content: data, completion: .contentProcessed({ sendError in
                    if let sendError = sendError {
                        NSLog("[ThinkingProxy] Send response error: \(sendError)")
                    }
                    
                    if isComplete {
                        targetConnection.cancel()
                        // Always close client connection - no keep-alive/pipelining support
                        originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                            originalConnection.cancel()
                        }))
                    } else {
                        // Schedule next iteration of the streaming loop
                        self.streamNextChunk(from: targetConnection, to: originalConnection)
                    }
                }))
            } else if isComplete {
                targetConnection.cancel()
                // Always close client connection - no keep-alive/pipelining support
                originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                    originalConnection.cancel()
                }))
            }
        }
    }
    
    /**
     Sends an error response to the client
     */
    private func sendError(to connection: NWConnection, statusCode: Int, message: String) {
        // Build response with proper CRLF line endings and correct byte count
        guard let bodyData = message.data(using: .utf8) else {
            connection.cancel()
            return
        }
        
        let headers = "HTTP/1.1 \(statusCode) \(message)\r\n" +
                     "Content-Type: text/plain\r\n" +
                     "Content-Length: \(bodyData.count)\r\n" +
                     "Connection: close\r\n" +
                     "\r\n"
        
        guard let headerData = headers.data(using: .utf8) else {
            connection.cancel()
            return
        }
        
        var responseData = Data()
        responseData.append(headerData)
        responseData.append(bodyData)
        
        connection.send(content: responseData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private func sendRedirect(to connection: NWConnection, location: String) {
        let headers = "HTTP/1.1 302 Found\r\n" +
                     "Location: \(location)\r\n" +
                     "Content-Length: 0\r\n" +
                     "Connection: close\r\n" +
                     "\r\n"

        guard let headerData = headers.data(using: .utf8) else {
            connection.cancel()
            return
        }

        connection.send(content: headerData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
}
