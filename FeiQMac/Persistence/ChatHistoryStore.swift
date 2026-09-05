import Foundation
import SQLite3

enum ChatHistoryStoreError: LocalizedError {
    case databaseUnavailable(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable(let message), .sqlite(let message):
            return message
        }
    }
}

private struct LegacyChatHistoryArchive: Decodable {
    let version: Int
    let messagesByPeer: [String: [ChatMessage]]
    let peers: [FeiQPeer]
    let groups: [ChatGroup]
    let unreadCountsByPeer: [String: Int]

    private enum CodingKeys: String, CodingKey {
        case version
        case messagesByPeer
        case peers
        case groups
        case unreadCountsByPeer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        messagesByPeer = try container.decode(
            [String: [ChatMessage]].self,
            forKey: .messagesByPeer
        )
        peers = try container.decode([FeiQPeer].self, forKey: .peers)
        groups = try container.decodeIfPresent(
            [ChatGroup].self,
            forKey: .groups
        ) ?? []
        unreadCountsByPeer = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .unreadCountsByPeer
        ) ?? [:]
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class ChatHistoryStore {
    private let queue = DispatchQueue(
        label: "com.local.feiqmac.chat-history",
        qos: .utility
    )
    private let databaseURL: URL
    private let legacyURL: URL
    private var database: OpaquePointer?
    private var initializationError: Error?

    var locationDescription: String {
        databaseURL.path
    }

    init(databaseURL: URL, legacyURL: URL) {
        self.databaseURL = databaseURL
        self.legacyURL = legacyURL
        self.database = nil
        self.initializationError = nil

        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            initializationError = error
            return
        }

        queue.sync {
            openDatabase()
        }
    }

    deinit {
        queue.sync {
            if let database {
                sqlite3_close(database)
                self.database = nil
            }
        }
    }

    func loadSnapshot(
        completion: @escaping (Result<ChatHistorySnapshot, Error>) -> Void
    ) {
        queue.async {
            do {
                try self.migrateLegacyJSONIfNeeded()
                let peers = try self.fetchPeers()
                let groups = try self.fetchGroups()
                var unreadCounts = Dictionary(
                    uniqueKeysWithValues: peers.compactMap { peer -> (String, Int)? in
                        guard peer.unreadCount > 0 else { return nil }
                        return (peer.peerID, peer.unreadCount)
                    }
                )
                for group in groups where group.unreadCount > 0 {
                    unreadCounts[group.group.id] = group.unreadCount
                }
                let storedPeers = peers.map { $0.peer }
                let storedGroups = groups.map { $0.group }
                let totalMessageCount = try self.fetchTotalMessageCount()
                completion(
                    .success(
                        ChatHistorySnapshot(
                            peers: storedPeers,
                            groups: storedGroups,
                            unreadCountsByPeer: unreadCounts,
                            totalMessageCount: totalMessageCount
                        )
                    )
                )
            } catch {
                completion(.failure(error))
            }
        }
    }

    func savePeer(_ peer: FeiQPeer) {
        enqueue {
            try self.upsertPeer(peer)
        }
    }

    func saveGroup(_ group: ChatGroup) {
        enqueue {
            try self.performTransaction {
                try self.upsertGroup(group)
            }
        }
    }

    func deleteGroup(_ groupID: String) {
        enqueue {
            try self.performTransaction {
                try self.deleteGroupMembers(groupID: groupID)
                try self.deleteGroupConversation(groupID: groupID)
                try self.deleteGroupRecord(groupID: groupID)
            }
        }
    }

    func saveMessage(
        _ message: ChatMessage,
        for peer: FeiQPeer,
        unreadCount: Int
    ) {
        enqueue {
            try self.performTransaction {
                try self.upsertPeer(peer)
                try self.insertMessage(message, conversationID: peer.id)
                try self.updateUnreadCount(
                    unreadCount,
                    for: peer.id
                )
            }
        }
    }

    func saveMessage(
        _ message: ChatMessage,
        for group: ChatGroup,
        unreadCount: Int
    ) {
        enqueue {
            try self.performTransaction {
                try self.upsertGroup(group)
                try self.insertMessage(message, conversationID: group.id)
                try self.updateUnreadCount(
                    unreadCount,
                    for: group.id
                )
            }
        }
    }

    func setUnreadCount(_ count: Int, for peerID: String) {
        enqueue {
            try self.updateUnreadCount(max(0, count), for: peerID)
        }
    }

    func loadRecentMessages(
        for peerID: String,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    ) {
        queue.async {
            do {
                let page = try self.fetchMessages(
                    for: peerID,
                    before: nil,
                    limit: limit
                )
                completion(.success(page))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func loadEarlierMessages(
        for peerID: String,
        before message: ChatMessage,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    ) {
        queue.async {
            do {
                let page = try self.fetchMessages(
                    for: peerID,
                    before: message,
                    limit: limit
                )
                completion(.success(page))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func openDatabase() {
        guard initializationError == nil else { return }

        let flags = SQLITE_OPEN_CREATE
            | SQLITE_OPEN_READWRITE
            | SQLITE_OPEN_FULLMUTEX
        var result = SQLITE_ERROR
        databaseURL.path.withCString { path in
            result = sqlite3_open_v2(path, &database, flags, nil)
        }

        guard result == SQLITE_OK, let database else {
            let message = self.database.map {
                String(cString: sqlite3_errmsg($0))
            } ?? "无法打开聊天记录数据库"
            if let database = self.database {
                sqlite3_close(database)
                self.database = nil
            }
            initializationError = ChatHistoryStoreError.sqlite(message)
            return
        }

        sqlite3_busy_timeout(database, 2_000)

        do {
            try execute(
                """
                PRAGMA journal_mode = WAL;
                PRAGMA synchronous = NORMAL;
                PRAGMA foreign_keys = ON;

                CREATE TABLE IF NOT EXISTS conversations (
                    peer_id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL DEFAULT '',
                    host_name TEXT NOT NULL DEFAULT '',
                    ip_address TEXT NOT NULL DEFAULT '',
                    group_name TEXT NOT NULL DEFAULT '',
                    last_seen REAL NOT NULL DEFAULT 0,
                    is_online INTEGER NOT NULL DEFAULT 0,
                    unread_count INTEGER NOT NULL DEFAULT 0,
                    conversation_kind TEXT NOT NULL DEFAULT 'peer'
                );

                CREATE TABLE IF NOT EXISTS chat_groups (
                    group_id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    owner_name TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS chat_group_members (
                    group_id TEXT NOT NULL,
                    peer_id TEXT NOT NULL,
                    sort_order INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(group_id, peer_id),
                    FOREIGN KEY(group_id) REFERENCES chat_groups(group_id)
                        ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_group_members_peer
                    ON chat_group_members(peer_id);

                CREATE TABLE IF NOT EXISTS messages (
                    id TEXT PRIMARY KEY NOT NULL,
                    peer_id TEXT NOT NULL,
                    direction TEXT NOT NULL,
                    text TEXT NOT NULL,
                    sender_name TEXT NOT NULL DEFAULT '',
                    recipient_name TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL,
                    FOREIGN KEY(peer_id) REFERENCES conversations(peer_id)
                        ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_messages_peer_time
                    ON messages(peer_id, created_at DESC, id DESC);

                CREATE TABLE IF NOT EXISTS store_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                """
            )
            try ensureConversationKindColumn()
        } catch {
            initializationError = error
            sqlite3_close(database)
            self.database = nil
        }
    }

    private func ensureConversationKindColumn() throws {
        var hasConversationKind = false
        do {
            let statement = try prepare("PRAGMA table_info(conversations)")
            defer { sqlite3_finalize(statement) }

            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    break
                }
                guard result == SQLITE_ROW else {
                    throw sqliteError()
                }
                if columnText(statement, 1) == "conversation_kind" {
                    hasConversationKind = true
                    break
                }
            }
        }

        if !hasConversationKind {
            try execute(
                "ALTER TABLE conversations ADD COLUMN conversation_kind TEXT NOT NULL DEFAULT 'peer'"
            )
        }
    }

    private func migrateLegacyJSONIfNeeded() throws {
        guard try metadataValue(for: "legacy_json_migrated") != "1" else {
            return
        }

        if try hasStoredData() {
            try setMetadata("legacy_json_migrated", value: "1")
            return
        }

        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            try setMetadata("legacy_json_migrated", value: "1")
            return
        }

        let data = try Data(contentsOf: legacyURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(LegacyChatHistoryArchive.self, from: data)

        try performTransaction {
            var peerIDs = Set<String>()
            var groupIDs = Set<String>()
            for peer in archive.peers {
                try upsertPeer(peer)
                peerIDs.insert(peer.id)
            }

            for group in archive.groups {
                try upsertGroup(group)
                groupIDs.insert(group.id)
            }

            for (peerID, messages) in archive.messagesByPeer {
                if !peerIDs.contains(peerID), !groupIDs.contains(peerID) {
                    try insertPlaceholderPeer(withID: peerID)
                    peerIDs.insert(peerID)
                }
                for message in messages {
                    try insertMessage(message, conversationID: peerID)
                }
            }

            for (peerID, count) in archive.unreadCountsByPeer where count > 0 {
                if !peerIDs.contains(peerID), !groupIDs.contains(peerID) {
                    try insertPlaceholderPeer(withID: peerID)
                    peerIDs.insert(peerID)
                }
                try updateUnreadCount(count, for: peerID)
            }

            try setMetadata("legacy_json_migrated", value: "1")
        }
    }

    private func hasStoredData() throws -> Bool {
        let conversationStatement = try prepare(
            "SELECT 1 FROM conversations LIMIT 1"
        )
        defer { sqlite3_finalize(conversationStatement) }
        if sqlite3_step(conversationStatement) == SQLITE_ROW {
            return true
        }

        let messageStatement = try prepare("SELECT 1 FROM messages LIMIT 1")
        defer { sqlite3_finalize(messageStatement) }
        return sqlite3_step(messageStatement) == SQLITE_ROW
    }

    private func fetchPeers() throws -> [(peer: FeiQPeer, peerID: String, unreadCount: Int)] {
        let statement = try prepare(
            """
            SELECT peer_id, name, host_name, ip_address, group_name,
                   last_seen, is_online, unread_count
            FROM conversations
            WHERE conversation_kind = 'peer'
            """
        )
        defer { sqlite3_finalize(statement) }

        var result: [(peer: FeiQPeer, peerID: String, unreadCount: Int)] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW else {
                throw sqliteError()
            }

            let peerID = columnText(statement, 0)
            let peer = FeiQPeer(
                id: peerID,
                name: columnText(statement, 1),
                hostName: columnText(statement, 2),
                ipAddress: columnText(statement, 3),
                group: columnText(statement, 4),
                lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                isOnline: sqlite3_column_int(statement, 6) != 0
            )
            result.append(
                (
                    peer: peer,
                    peerID: peerID,
                    unreadCount: Int(sqlite3_column_int(statement, 7))
                )
            )
        }
        return result
    }

    private func fetchGroups() throws -> [(group: ChatGroup, unreadCount: Int)] {
        let statement = try prepare(
            """
            SELECT g.group_id, g.name, g.owner_name, g.created_at,
                   COALESCE(c.unread_count, 0)
            FROM chat_groups AS g
            LEFT JOIN conversations AS c ON c.peer_id = g.group_id
            ORDER BY g.created_at ASC, g.group_id ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var result: [(group: ChatGroup, unreadCount: Int)] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW else {
                throw sqliteError()
            }

            let groupID = columnText(statement, 0)
            let memberStatement = try prepare(
                """
                SELECT peer_id
                FROM chat_group_members
                WHERE group_id = ?
                ORDER BY sort_order ASC, peer_id ASC
                """
            )
            defer { sqlite3_finalize(memberStatement) }
            try bindText(groupID, at: 1, in: memberStatement)

            var memberIDs: [String] = []
            while true {
                let memberStep = sqlite3_step(memberStatement)
                if memberStep == SQLITE_DONE {
                    break
                }
                guard memberStep == SQLITE_ROW else {
                    throw sqliteError()
                }
                memberIDs.append(columnText(memberStatement, 0))
            }

            let group = ChatGroup(
                id: groupID,
                name: columnText(statement, 1),
                memberIDs: memberIDs,
                ownerName: columnText(statement, 2),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            )
            result.append(
                (
                    group: group,
                    unreadCount: Int(sqlite3_column_int(statement, 4))
                )
            )
        }
        return result
    }

    private func fetchTotalMessageCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM messages")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError()
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func fetchMessages(
        for peerID: String,
        before beforeMessage: ChatMessage?,
        limit: Int
    ) throws -> ChatHistoryPage {
        let pageSize = max(1, min(limit, 200))
        let statement: OpaquePointer

        if beforeMessage == nil {
            statement = try prepare(
                """
                SELECT id, direction, text, sender_name, recipient_name, created_at
                FROM messages
                WHERE peer_id = ?
                ORDER BY created_at DESC, id DESC
                LIMIT ?
                """
            )
        } else {
            statement = try prepare(
                """
                SELECT id, direction, text, sender_name, recipient_name, created_at
                FROM messages
                WHERE peer_id = ?
                  AND (
                      created_at < ?
                      OR (created_at = ? AND id < ?)
                  )
                ORDER BY created_at DESC, id DESC
                LIMIT ?
                """
            )
        }
        defer { sqlite3_finalize(statement) }

        try bindText(peerID, at: 1, in: statement)
        if let beforeMessage {
            try bindDouble(beforeMessage.date.timeIntervalSince1970, at: 2, in: statement)
            try bindDouble(beforeMessage.date.timeIntervalSince1970, at: 3, in: statement)
            try bindText(beforeMessage.id.uuidString, at: 4, in: statement)
            try bindInt32(Int32(pageSize + 1), at: 5, in: statement)
        } else {
            try bindInt32(Int32(pageSize + 1), at: 2, in: statement)
        }

        var rows: [ChatMessage] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW else {
                throw sqliteError()
            }
            rows.append(message(from: statement))
        }

        let hasMore = rows.count > pageSize
        return ChatHistoryPage(
            messages: Array(rows.prefix(pageSize).reversed()),
            hasMore: hasMore
        )
    }

    private func message(from statement: OpaquePointer) -> ChatMessage {
        ChatMessage(
            id: UUID(uuidString: columnText(statement, 0)) ?? UUID(),
            direction: ChatMessageDirection(rawValue: columnText(statement, 1))
                ?? .incoming,
            text: columnText(statement, 2),
            senderName: columnText(statement, 3),
            recipientName: columnText(statement, 4),
            date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        )
    }

    private func upsertPeer(_ peer: FeiQPeer) throws {
        let statement = try prepare(
            """
            INSERT INTO conversations (
                peer_id, name, host_name, ip_address, group_name,
                last_seen, is_online, unread_count, conversation_kind
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, 'peer')
            ON CONFLICT(peer_id) DO UPDATE SET
                name = excluded.name,
                host_name = excluded.host_name,
                ip_address = excluded.ip_address,
                group_name = excluded.group_name,
                last_seen = excluded.last_seen,
                is_online = excluded.is_online,
                conversation_kind = 'peer'
            """
        )
        defer { sqlite3_finalize(statement) }

        try bindText(peer.id, at: 1, in: statement)
        try bindText(peer.name, at: 2, in: statement)
        try bindText(peer.hostName, at: 3, in: statement)
        try bindText(peer.ipAddress, at: 4, in: statement)
        try bindText(peer.group, at: 5, in: statement)
        try bindDouble(peer.lastSeen.timeIntervalSince1970, at: 6, in: statement)
        try bindInt32(peer.isOnline ? 1 : 0, at: 7, in: statement)
        try stepDone(statement)
    }

    private func upsertGroup(_ group: ChatGroup) throws {
        let conversationStatement = try prepare(
            """
            INSERT INTO conversations (
                peer_id, name, host_name, ip_address, group_name,
                last_seen, is_online, unread_count, conversation_kind
            )
            VALUES (?, ?, '', '', '', ?, 0, 0, 'group')
            ON CONFLICT(peer_id) DO UPDATE SET
                name = excluded.name,
                last_seen = excluded.last_seen,
                conversation_kind = 'group'
            """
        )
        defer { sqlite3_finalize(conversationStatement) }
        try bindText(group.id, at: 1, in: conversationStatement)
        try bindText(group.displayName, at: 2, in: conversationStatement)
        try bindDouble(group.createdAt.timeIntervalSince1970, at: 3, in: conversationStatement)
        try stepDone(conversationStatement)

        let groupStatement = try prepare(
            """
            INSERT INTO chat_groups(group_id, name, owner_name, created_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(group_id) DO UPDATE SET
                name = excluded.name,
                owner_name = excluded.owner_name,
                created_at = excluded.created_at
            """
        )
        defer { sqlite3_finalize(groupStatement) }
        try bindText(group.id, at: 1, in: groupStatement)
        try bindText(group.displayName, at: 2, in: groupStatement)
        try bindText(group.ownerName, at: 3, in: groupStatement)
        try bindDouble(group.createdAt.timeIntervalSince1970, at: 4, in: groupStatement)
        try stepDone(groupStatement)

        try deleteGroupMembers(groupID: group.id)
        for (index, memberID) in group.memberIDs.enumerated() {
            let memberStatement = try prepare(
                """
                INSERT INTO chat_group_members(group_id, peer_id, sort_order)
                VALUES (?, ?, ?)
                ON CONFLICT(group_id, peer_id) DO UPDATE SET
                    sort_order = excluded.sort_order
                """
            )
            defer { sqlite3_finalize(memberStatement) }
            try bindText(group.id, at: 1, in: memberStatement)
            try bindText(memberID, at: 2, in: memberStatement)
            try bindInt32(Int32(index), at: 3, in: memberStatement)
            try stepDone(memberStatement)
        }
    }

    private func deleteGroupMembers(groupID: String) throws {
        let statement = try prepare(
            "DELETE FROM chat_group_members WHERE group_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bindText(groupID, at: 1, in: statement)
        try stepDone(statement)
    }

    private func deleteGroupConversation(groupID: String) throws {
        let statement = try prepare(
            "DELETE FROM conversations WHERE peer_id = ? AND conversation_kind = 'group'"
        )
        defer { sqlite3_finalize(statement) }
        try bindText(groupID, at: 1, in: statement)
        try stepDone(statement)
    }

    private func deleteGroupRecord(groupID: String) throws {
        let statement = try prepare(
            "DELETE FROM chat_groups WHERE group_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bindText(groupID, at: 1, in: statement)
        try stepDone(statement)
    }

    private func insertPlaceholderPeer(withID peerID: String) throws {
        let peer = FeiQPeer(
            id: peerID,
            name: "",
            hostName: "",
            ipAddress: peerID,
            group: "",
            lastSeen: Date(timeIntervalSince1970: 0),
            isOnline: false
        )
        try upsertPeer(peer)
    }

    private func insertMessage(_ message: ChatMessage, conversationID: String) throws {
        let statement = try prepare(
            """
            INSERT OR IGNORE INTO messages (
                id, peer_id, direction, text, sender_name, recipient_name, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        try bindText(message.id.uuidString, at: 1, in: statement)
        try bindText(conversationID, at: 2, in: statement)
        try bindText(message.direction.rawValue, at: 3, in: statement)
        try bindText(message.text, at: 4, in: statement)
        try bindText(message.senderName, at: 5, in: statement)
        try bindText(message.recipientName, at: 6, in: statement)
        try bindDouble(message.date.timeIntervalSince1970, at: 7, in: statement)
        try stepDone(statement)
    }

    private func updateUnreadCount(_ count: Int, for peerID: String) throws {
        let statement = try prepare(
            """
            UPDATE conversations
            SET unread_count = ?
            WHERE peer_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        try bindInt32(Int32(max(0, count)), at: 1, in: statement)
        try bindText(peerID, at: 2, in: statement)
        try stepDone(statement)
    }

    private func metadataValue(for key: String) throws -> String? {
        let statement = try prepare(
            "SELECT value FROM store_metadata WHERE key = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bindText(key, at: 1, in: statement)

        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return nil
        }
        guard result == SQLITE_ROW else {
            throw sqliteError()
        }
        return columnText(statement, 0)
    }

    private func setMetadata(_ key: String, value: String) throws {
        let statement = try prepare(
            """
            INSERT INTO store_metadata(key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
        defer { sqlite3_finalize(statement) }
        try bindText(key, at: 1, in: statement)
        try bindText(value, at: 2, in: statement)
        try stepDone(statement)
    }

    private func performTransaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try operation()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func enqueue(_ operation: @escaping () throws -> Void) {
        queue.async {
            do {
                try operation()
            } catch {
                NSLog("飞秋聊天记录数据库写入失败：%@", error.localizedDescription)
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else {
            throw initializationError
                ?? ChatHistoryStoreError.databaseUnavailable("聊天记录数据库未打开")
        }

        var statement: OpaquePointer?
        var result = SQLITE_ERROR
        sql.withCString { sqlPointer in
            result = sqlite3_prepare_v2(
                database,
                sqlPointer,
                -1,
                &statement,
                nil
            )
        }
        guard result == SQLITE_OK, let statement else {
            throw sqliteError()
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard let database else {
            throw initializationError
                ?? ChatHistoryStoreError.databaseUnavailable("聊天记录数据库未打开")
        }

        var errorMessage: UnsafeMutablePointer<CChar>?
        var result = SQLITE_ERROR
        sql.withCString { sqlPointer in
            result = sqlite3_exec(
                database,
                sqlPointer,
                nil,
                nil,
                &errorMessage
            )
        }

        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? sqliteMessage
            if let errorMessage {
                sqlite3_free(UnsafeMutableRawPointer(errorMessage))
            }
            throw ChatHistoryStoreError.sqlite(message)
        }
        if let errorMessage {
            sqlite3_free(UnsafeMutableRawPointer(errorMessage))
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError()
        }
    }

    private func bindText(
        _ value: String,
        at index: Int32,
        in statement: OpaquePointer
    ) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func bindDouble(
        _ value: Double,
        at index: Int32,
        in statement: OpaquePointer
    ) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func bindInt32(
        _ value: Int32,
        at index: Int32,
        in statement: OpaquePointer
    ) throws {
        guard sqlite3_bind_int(statement, index, value) == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else {
            return ""
        }
        let pointer = UnsafeRawPointer(value).assumingMemoryBound(to: CChar.self)
        return String(cString: pointer)
    }

    private var sqliteMessage: String {
        guard let database else { return "SQLite 未知错误" }
        return String(cString: sqlite3_errmsg(database))
    }

    private func sqliteError() -> ChatHistoryStoreError {
        .sqlite(sqliteMessage)
    }
}
