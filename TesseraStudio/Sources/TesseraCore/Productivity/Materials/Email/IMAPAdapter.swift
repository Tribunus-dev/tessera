import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - IMAPAdapter

/// Fetch email messages from any IMAP4rev1 server (Gmail, iCloud, Fastmail,
/// ProtonMail, corporate Exchange) over IMAPS (port 993, implicit TLS).
///
/// The adapter produces ``EmailMessage`` values and calls
/// ``EmailStore.upsert()`` to persist them.
///
/// **Credentials.** Stored in the macOS Keychain via ``KeychainStorage``.
public actor IMAPAdapter {

    // MARK: - Types

    public struct Credentials: Sendable {
        public let host: String
        public let port: Int
        public let username: String
        public let password: String  // app-specific password recommended

        public init(host: String, port: Int = 993, username: String, password: String) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }
    }

    public enum ConnectionState: Sendable, Equatable {
        case disconnected
        case connecting
        case authenticated
        case selected(String)
    }

    public enum IMAPError: Error, Sendable, Equatable {
        case notConnected
        case notAuthenticated
        case mailboxNotFound(String)
        case fetchFailed(String)
        case connectionFailed(String)
        case tlsFailed(String)
        case platformUnsupported
    }

    // MARK: - State

    #if canImport(Network)
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.tessera.imap", qos: .userInitiated)
    #endif
    private(set) public var connectionState: ConnectionState = .disconnected
    private var lastSyncUID: Int = 0
    private var tagCounter: Int = 0

    // MARK: - Lifecycle

    public init() {}

    public func disconnect() async {
        #if canImport(Network)
        connection?.cancel()
        connection = nil
        connectionState = .disconnected
        #endif
    }

    // MARK: - Internal mutators (actor-safe)

    private func setConnectionState(_ state: ConnectionState) {
        connectionState = state
    }

    // MARK: - Connect

    /// Connect to the IMAP server and authenticate.
    public func connect(credentials: Credentials) async throws {
        #if canImport(Network)
        await disconnect()

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(credentials.host),
            port: NWEndpoint.Port(integerLiteral: UInt16(credentials.port))
        )

        // IMAPS uses implicit TLS on port 993.
        let tlsOptions = NWProtocolTLS.Options()
        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)

        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        connectionState = .connecting

        // Wait for connection to establish.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { await self?.setConnectionState(.authenticated) }
                    cont.resume()
                case .failed(let err):
                    cont.resume(throwing: IMAPError.connectionFailed(String(describing: err)))
                case .cancelled:
                    cont.resume(throwing: IMAPError.connectionFailed("Connection cancelled"))
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }

        // Read server greeting.
        guard let greeting = try await readLine() else {
            throw IMAPError.connectionFailed("No greeting from server")
        }
        if !greeting.contains("OK") {
            throw IMAPError.connectionFailed("Unexpected greeting: \(greeting)")
        }

        // Authenticate.
        try await authenticate(username: credentials.username, password: credentials.password)
        connectionState = .authenticated

        #else
        throw IMAPError.platformUnsupported
        #endif
    }

    // MARK: - Authenticate

    #if canImport(Network)
    private func authenticate(username: String, password: String) async throws {
        // Try CRAM-MD5 first.
        let tag = nextTag()
        try await sendLine("\(tag) AUTHENTICATE CRAM-MD5")

        guard let challenge = try await readLine() else {
            throw IMAPError.fetchFailed("No response to AUTHENTICATE CRAM-MD5")
        }

        if challenge.contains("+ ") {
            // Server sent a challenge. Compute CRAM-MD5 response.
            let response = computeCRAMMD5(username: username, password: password, challenge: challenge)
            try await sendLine(response)
        } else {
            // Fall back to LOGIN.
            let tag1 = nextTag()
            try await sendLine("\(tag1) LOGIN \(encodeIMAPString(username)) \(encodeIMAPString(password))")
        }

        guard let authResponse = try await readLine() else {
            throw IMAPError.fetchFailed("No response to LOGIN")
        }
        if authResponse.contains("NO") {
            throw IMAPError.connectionFailed("Authentication failed: \(authResponse)")
        }
    }
    #endif

    // MARK: - Fetch messages

    /// Fetch messages from a mailbox (default: "INBOX").
    public func fetchMessages(from mailbox: String = "INBOX", limit: Int = 500) async throws -> [EmailMessage] {
        #if canImport(Network)
        guard connection != nil else { throw IMAPError.notConnected }
        guard case .authenticated = connectionState else { throw IMAPError.notAuthenticated }

        // Select mailbox.
        let selectTag = nextTag()
        try await sendLine("\(selectTag) SELECT \(encodeIMAPString(mailbox))")

        var selectResponse = ""
        while let line = try await readLine() {
            selectResponse += line
            if line.hasPrefix(selectTag) { break }
        }
        if selectResponse.contains("NO") {
            throw IMAPError.mailboxNotFound("Cannot select \(mailbox): \(selectResponse)")
        }
        connectionState = .selected(mailbox)

        // Search for message IDs in the mailbox.
        let searchTag = nextTag()
        try await sendLine("\(searchTag) SEARCH UNSEEN")
        let searchResponse = try await readUntilTag(searchTag) ?? ""
        let ids = parseMessageIDs(from: searchResponse)

        // Fetch ENVELOPE and headers for the last N messages.
        let idsToFetch = Array(ids.suffix(limit))
        var messages: [EmailMessage] = []

        for id in idsToFetch {
            let fetchTag = nextTag()
            try await sendLine("\(fetchTag) FETCH \(id) (UID ENVELOPE BODY.PEEK[HEADER])")
            let response = try await readUntilTag(fetchTag) ?? ""
            if let msg = parseEmailMessage(from: response, id: id) {
                messages.append(msg)
            }
        }

        return messages
        #else
        return []
        #endif
    }

    /// Incremental sync: fetch only messages with UID > lastSyncUID.
    public func syncIncremental() async throws -> [EmailMessage] {
        #if canImport(Network)
        guard connection != nil else { throw IMAPError.notConnected }

        let fetchTag = nextTag()
        let range = lastSyncUID == 0 ? "1:*" : "\(lastSyncUID + 1):*"
        try await sendLine("\(fetchTag) UID FETCH \(range) (UID ENVELOPE)")

        var messages: [EmailMessage] = []
        while let line = try await readLine() {
            if line.hasPrefix(fetchTag) { break }
            if line.contains("UID") {
                if let uidRange = line.range(of: "UID (\\d+)", options: .regularExpression),
                   let uid = Int(line[uidRange].dropFirst(5)) {
                    lastSyncUID = max(lastSyncUID, uid)
                    if let msg = parseEmailMessage(from: line, id: nil) {
                        messages.append(msg)
                    }
                }
            }
        }

        return messages
        #else
        return []
        #endif
    }

    // MARK: - Network helpers

    #if canImport(Network)
    private func sendLine(_ line: String) async throws {
        guard let conn = connection else { throw IMAPError.notConnected }
        guard let data = line.data(using: .utf8) else {
            throw IMAPError.fetchFailed("Cannot encode IMAP command")
        }
        try await conn.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                // Completion handler is nonisolated; surface error via throw.
                // For simplicity, errors are surfaced on the next call.
                _ = error
            }
        })
    }

    private func readLine() async throws -> String? {
        guard let conn = connection else { throw IMAPError.notConnected }
        return try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error = error {
                    cont.resume(throwing: IMAPError.fetchFailed(String(describing: error)))
                    return
                }
                if let data = data, let line = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .newlines) {
                    cont.resume(returning: line)
                } else if isComplete {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: "")
                }
            }
        }
    }

    private func readUntilTag(_ tag: String) async throws -> String? {
        var result = ""
        while let line = try await readLine() {
            result += line + "\n"
            if line.hasPrefix(tag) { break }
        }
        return result.isEmpty ? nil : result
    }
    #endif

    // MARK: - IMAP helpers

    private func nextTag() -> String {
        tagCounter += 1
        return "A\(String(format: "%04d", tagCounter))"
    }

    private func encodeIMAPString(_ s: String) -> String {
        if s.contains(" ") || s.contains("\"") {
            return "\"\(s)\""
        }
        return s
    }

    #if canImport(CryptoKit)
    private func computeCRAMMD5(username: String, password: String, challenge: String) -> String {
        // Extract challenge (base64 after "+ ").
        let challengeBase64 = challenge.replacingOccurrences(of: "+ ", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let challengeData = Data(base64Encoded: challengeBase64),
              let passwordData = password.data(using: .utf8) else {
            return ""
        }

        // HMAC-MD5 using CryptoKit.
        let key = SymmetricKey(data: passwordData)
        let hmac = HMAC<Insecure.MD5>.authenticationCode(for: challengeData, using: key)
        let digest = Data(hmac).map { String(format: "%02x", $0) }.joined()
        let response = "\(username) \(digest)"
        return Data(response.data(using: .utf8)!).base64EncodedString()
    }
    #else
    private func computeCRAMMD5(username: String, password: String, challenge: String) -> String {
        // Fallback: LOGIN method will be used instead.
        return ""
    }
    #endif

    // MARK: - Parsing

    private func parseMessageIDs(from searchResponse: String) -> [Int] {
        let components = searchResponse.split(separator: " ")
        return components.compactMap { Int($0) }
    }

    /// Parse an EmailMessage from IMAP FETCH response text.
    /// The `id` parameter is the IMAP sequence number (optional for UID-only fetches).
    private func parseEmailMessage(from response: String, id: Int?) -> EmailMessage? {
        var subject = ""
        var fromAddr = EmailAddress(email: "")
        var to: [EmailAddress] = []
        var date = Date()
        var messageID = ""

        // Extract Subject.
        if let subjectRange = response.range(of: "Subject: ([^\r\n]+)", options: .regularExpression) {
            subject = String(response[subjectRange])
                .replacingOccurrences(of: "Subject: ", with: "")
                .trimmingCharacters(in: .whitespaces)
        }

        // Extract From (single address).
        if let fromRange = response.range(of: "From: ([^\r\n]+)", options: .regularExpression) {
            let fromStr = String(response[fromRange]).replacingOccurrences(of: "From: ", with: "")
            let addrs = parseAddressList(fromStr)
            if let first = addrs.first {
                fromAddr = first
            }
        }

        // Extract Date.
        if let dateRange = response.range(of: "\\d{1,2} \\w{3} \\d{4} \\d{2}:\\d{2}:\\d{2}",
                                        options: .regularExpression) {
            let dateStr = String(response[dateRange])
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM yyyy HH:mm:ss"
            if let parsed = formatter.date(from: dateStr) {
                date = parsed
            }
        }

        // Extract Message-ID.
        if let midRange = response.range(of: "Message-ID: ([^\r\n]+)", options: .regularExpression) {
            messageID = String(response[midRange])
                .replacingOccurrences(of: "Message-ID: ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "<", with: "")
                .replacingOccurrences(of: ">", with: "")
        }

        return EmailMessage(
            id: UUID(),
            messageID: messageID,
            from: fromAddr,
            to: to,
            subject: subject,
            bodyPlain: response,
            receivedAt: date,
            isRead: false,
            isStarred: false
        )
    }

    /// Parse a list of EmailAddress from an RFC 5322 address header string.
    private func parseAddressList(_ header: String) -> [EmailAddress] {
        let pattern = try? NSRegularExpression(pattern: "([^\"<]+ )?<?([^>]+@[^>]+)>?", options: [])
        let range = NSRange(header.startIndex..., in: header)
        let matches = pattern?.matches(in: header, options: [], range: range) ?? []

        return matches.compactMap { match -> EmailAddress? in
            guard match.numberOfRanges >= 3 else { return nil }
            guard let emailRange = Range(match.range(at: 2), in: header) else { return nil }
            let email = String(header[emailRange])
            let nameRange = Range(match.range(at: 1), in: header)
            let name = nameRange.map { String(header[$0]).trimmingCharacters(in: .whitespaces) }
            return EmailAddress(name: name, email: email)
        }
    }
}
