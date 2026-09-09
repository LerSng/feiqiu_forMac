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
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let databaseURL: URL
    private let legacyURL: URL
    private var database: OpaquePointer?
    private var initializationError: Error?
    private var restoredDuringThisRun = false
    private var hasPreparedPeerIdentities = false

    var maintenanceRequiresRestart: Bool {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return restoredDuringThisRun }
        return queue.sync { restoredDuringThisRun }
    }

    func withMaintenanceDatabase<Value>(requiresRestart: Bool,
        operation: @escaping (OpaquePointer, URL) throws -> Value,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        queue.async {
            completion(Result {
                guard !self.restoredDuringThisRun else { throw DatabaseMaintenanceError.restartRequired }
                try self.preparePeerIdentities()
                guard let database = self.database else {
                    throw self.initializationError ?? DatabaseMaintenanceError.database("数据库未打开")
                }
                let value = try operation(database, self.databaseURL)
                if requiresRestart { self.restoredDuringThisRun = true }
                return value
            })
        }
    }

    var locationDescription: String {
        databaseURL.path
    }

    init(databaseURL: URL, legacyURL: URL) {
        self.databaseURL = databaseURL
        self.legacyURL = legacyURL
        self.database = nil
        self.initializationError = nil
        queue.setSpecific(key: queueKey, value: 1)

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
        // A queued write can own the last reference. Synchronizing onto
        // that same queue during deinit would trigger a libdispatch trap.
        let connection = database
        database = nil
        let close = {
            if let connection { sqlite3_close(connection) }
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            close()
        } else {
            queue.sync(execute: close)
        }
    }

    func loadConversationSettings() throws -> [String: ConversationSettings] {
        let load = { [self] () throws -> [String: ConversationSettings] in
            try preparePeerIdentities()
            let statement = try prepare("SELECT conversation_id, settings_json FROM conversation_settings;")
            defer { sqlite3_finalize(statement) }
            var settings: [String: ConversationSettings] = [:]
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return settings }
                guard result == SQLITE_ROW,
                      let identifier = sqlite3_column_text(statement, 0),
                      let json = sqlite3_column_text(statement, 1) else { throw sqliteError() }
                settings[String(cString: identifier)] = try JSONDecoder()
                    .decode(ConversationSettings.self, from: Data(String(cString: json).utf8)).validated()
            }
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try load() }
        return try queue.sync(execute: load)
    }

    func saveConversationSettings(_ settings: ConversationSettings, for conversationID: String,
                                  completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            completion(Result {
                guard !conversationID.isEmpty else { throw ConversationSettingsError.unavailable }
                let normalized = try settings.validated()
                try self.performTransaction {
                    let sql = normalized.isDefault
                        ? "DELETE FROM conversation_settings WHERE conversation_id = ?;"
                        : "INSERT INTO conversation_settings(conversation_id, settings_json) VALUES (?, ?) ON CONFLICT(conversation_id) DO UPDATE SET settings_json = excluded.settings_json;"
                    let statement = try self.prepare(sql)
                    defer { sqlite3_finalize(statement) }
                    try self.bindText(conversationID, at: 1, in: statement)
                    if !normalized.isDefault {
                        let json = String(decoding: try JSONEncoder().encode(normalized), as: UTF8.self)
                        try self.bindText(json, at: 2, in: statement)
                    }
                    try self.stepDone(statement)
                    if normalized.isBlocked {
                        let clearUnread = try self.prepare("UPDATE conversations SET unread_count = 0 WHERE peer_id = ?;")
                        defer { sqlite3_finalize(clearUnread) }
                        try self.bindText(conversationID, at: 1, in: clearUnread)
                        try self.stepDone(clearUnread)
                    }
                }
            })
        }
    }

    func loadSnapshot(
        completion: @escaping (Result<ChatHistorySnapshot, Error>) -> Void
    ) {
        queue.async {
            do {
                try self.preparePeerIdentities()
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

    func removeImage(
        attachmentID: String, messageID: UUID, conversationID: String,
        deleteUnreferencedFile: @escaping (ChatAttachment) throws -> Void,
        completion: @escaping (Result<ChatMessage, Error>) -> Void
    ) {
        queue.async {
            do {
                var updatedMessage: ChatMessage?
                try self.performTransaction {
                    let statement = try self.prepare("""
                        SELECT id, direction, text, sender_name, recipient_name,
                               attachments_json, created_at
                        FROM messages WHERE id = ? AND peer_id = ?
                        """)
                    defer { sqlite3_finalize(statement) }
                    try self.bindText(messageID.uuidString, at: 1, in: statement)
                    try self.bindText(conversationID, at: 2, in: statement)
                    guard sqlite3_step(statement) == SQLITE_ROW else {
                        throw ChatHistoryStoreError.sqlite("待删除图片的聊天记录不存在")
                    }
                    let original = self.message(from: statement)
                    guard let removed = original.attachments.first(where: { $0.id == attachmentID && $0.isImage }) else {
                        updatedMessage = original
                        return
                    }
                    let tombstone = try self.prepare(
                        "INSERT OR IGNORE INTO deleted_message_images(message_id, attachment_id) VALUES (?, ?)"
                    )
                    defer { sqlite3_finalize(tombstone) }
                    try self.bindText(messageID.uuidString, at: 1, in: tombstone)
                    try self.bindText(attachmentID, at: 2, in: tombstone)
                    try self.stepDone(tombstone)
                    let updated = original.removingImages(withIDs: [attachmentID])
                    try self.insertMessage(updated, conversationID: conversationID)
                    let references = try self.prepare("""
                        SELECT 1 FROM messages, json_each(messages.attachments_json) AS attachment
                        WHERE json_extract(attachment.value, '$.localPath') = ? LIMIT 1
                        """)
                    defer { sqlite3_finalize(references) }
                    try self.bindText(removed.localPath, at: 1, in: references)
                    let referenceResult = sqlite3_step(references)
                    if referenceResult == SQLITE_DONE {
                        try deleteUnreferencedFile(removed)
                    } else if referenceResult != SQLITE_ROW {
                        throw ChatHistoryStoreError.databaseUnavailable("无法检查图片引用")
                    }
                    updatedMessage = updated
                }
                guard let updatedMessage else {
                    throw ChatHistoryStoreError.sqlite("删除图片失败")
                }
                completion(.success(updatedMessage))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func deleteMessage(
        id: UUID,
        conversationID: String,
        completion: @escaping (Result<[ChatAttachment], Error>) -> Void
    ) {
        queue.async {
            do {
                var attachments: [ChatAttachment] = []
                try self.performTransaction {
                    let query = try self.prepare(
                        "SELECT attachments_json FROM messages WHERE id = ? AND peer_id = ?"
                    )
                    defer { sqlite3_finalize(query) }
                    try self.bindText(id.uuidString, at: 1, in: query)
                    try self.bindText(conversationID, at: 2, in: query)
                    guard sqlite3_step(query) == SQLITE_ROW else {
                        throw ChatHistoryStoreError.sqlite("聊天记录不存在")
                    }
                    let deletedAttachments = self.decodeAttachments(self.columnText(query, 0))

                    let deletion = try self.prepare(
                        "DELETE FROM messages WHERE id = ? AND peer_id = ?"
                    )
                    defer { sqlite3_finalize(deletion) }
                    try self.bindText(id.uuidString, at: 1, in: deletion)
                    try self.bindText(conversationID, at: 2, in: deletion)
                    try self.stepDone(deletion)

                    for attachment in deletedAttachments {
                        let references = try self.prepare("""
                            SELECT 1 FROM messages, json_each(messages.attachments_json) AS attachment
                            WHERE json_extract(attachment.value, '$.localPath') = ? LIMIT 1
                            """)
                        try self.bindText(attachment.localPath, at: 1, in: references)
                        let referenceResult = sqlite3_step(references)
                        sqlite3_finalize(references)
                        if referenceResult == SQLITE_DONE {
                            attachments.append(attachment)
                        } else if referenceResult != SQLITE_ROW {
                            throw ChatHistoryStoreError.databaseUnavailable("无法检查消息附件引用")
                        }
                    }
                }
                completion(.success(attachments))
            } catch {
                completion(.failure(error))
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

    func loadLaterMessages(
        for conversationID: String,
        after message: ChatMessage,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    ) {
        queue.async {
            do {
                completion(.success(try self.fetchMessages(
                    for: conversationID, before: nil, after: message, limit: limit
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func loadMessageContext(
        for conversationID: String,
        messageID: UUID,
        limit: Int,
        completion: @escaping (Result<ChatHistoryContext, Error>) -> Void
    ) {
        queue.async {
            do {
                let statement = try self.prepare("""
                    SELECT id, direction, text, sender_name, recipient_name,
                           attachments_json, created_at
                    FROM messages WHERE peer_id = ? AND id = ?
                    """)
                defer { sqlite3_finalize(statement) }
                try self.bindText(conversationID, at: 1, in: statement)
                try self.bindText(messageID.uuidString, at: 2, in: statement)
                let stepResult = sqlite3_step(statement)
                guard stepResult == SQLITE_ROW else {
                    if stepResult == SQLITE_DONE { throw ChatHistorySearchError.messageUnavailable }
                    throw self.sqliteError()
                }
                let target = self.message(from: statement)
                let sideLimit = max(1, min(limit, 200) / 2)
                let earlier = try self.fetchMessages(for: conversationID, before: target, limit: sideLimit)
                let later = try self.fetchMessages(for: conversationID, before: nil, after: target, limit: sideLimit)
                completion(.success(ChatHistoryContext(
                    messages: earlier.messages + [target] + later.messages,
                    hasEarlier: earlier.hasMore, hasLater: later.hasMore
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func loadArchive(
        matching query: ChatHistorySearchQuery,
        completion: @escaping (Result<ChatHistoryArchive, Error>) -> Void
    ) {
        queue.async {
            do {
                try self.migrateLegacyJSONIfNeeded()
                var records: [ChatArchivedMessage] = []
                var cursor: ChatHistorySearchCursor?
                var exportedPeers: [FeiQPeer] = []
                var exportedGroups: [ChatGroup] = []
                try self.performTransaction {
                    repeat {
                        let page = try self.fetchSearchResults(matching: query, before: cursor, limit: 200)
                        records += page.results.map { ChatArchivedMessage(conversationID: $0.conversationID, message: $0.message) }
                        cursor = page.hasMore ? page.results.last?.cursor : nil
                    } while cursor != nil
                    let conversationIDs = Set(records.map(\.conversationID))
                    exportedGroups = try self.fetchGroups().map(\.group).filter { conversationIDs.contains($0.id) }
                    let peerIDs = conversationIDs.union(exportedGroups.flatMap(\.memberIDs))
                    exportedPeers = try self.fetchPeers().map(\.peer).filter { peerIDs.contains($0.id) }
                }
                completion(.success(ChatHistoryArchive(
                    peers: exportedPeers, groups: exportedGroups, messages: Array(records.reversed())
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func importArchive(
        _ archive: ChatHistoryArchive,
        completion: @escaping (Result<ChatHistoryImportSummary, Error>) -> Void
    ) {
        queue.async {
            do {
                try archive.validate()
                try self.migrateLegacyJSONIfNeeded()
                var insertedIDs = Set<UUID>()
                var skippedCount = 0
                var addedPeers = 0
                var addedGroups = 0
                try self.performTransaction {
                    for peer in archive.peers {
                        if let kind = try self.conversationKind(for: peer.id) {
                            guard kind == "peer" else { throw ChatHistoryArchiveError.conflictingConversation }
                        } else {
                            var restored = peer
                            restored.isOnline = false
                            try self.upsertPeer(restored)
                            addedPeers += 1
                        }
                    }
                    for group in archive.groups {
                        if let kind = try self.conversationKind(for: group.id) {
                            guard kind == "group" else { throw ChatHistoryArchiveError.conflictingConversation }
                        } else {
                            var restored = group
                            restored.memberIDs = []
                            try self.upsertGroup(restored)
                            addedGroups += 1
                        }
                    }
                    for record in archive.messages {
                        let statement = try self.prepare("SELECT peer_id FROM messages WHERE id = ?")
                        defer { sqlite3_finalize(statement) }
                        try self.bindText(record.message.id.uuidString, at: 1, in: statement)
                        let stepResult = sqlite3_step(statement)
                        if stepResult == SQLITE_ROW {
                            guard self.columnText(statement, 0) == record.conversationID else {
                                throw ChatHistoryArchiveError.conflictingMessage
                            }
                            skippedCount += 1
                        } else {
                            guard stepResult == SQLITE_DONE else { throw self.sqliteError() }
                            try self.insertMessage(record.message, conversationID: record.conversationID)
                            insertedIDs.insert(record.message.id)
                        }
                    }
                }
                completion(.success(ChatHistoryImportSummary(
                    insertedMessageIDs: insertedIDs, skippedMessageCount: skippedCount,
                    addedPeerCount: addedPeers, addedGroupCount: addedGroups
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func conversationKind(for conversationID: String) throws -> String? {
        let statement = try prepare("SELECT conversation_kind FROM conversations WHERE peer_id = ?")
        defer { sqlite3_finalize(statement) }
        try bindText(conversationID, at: 1, in: statement)
        let stepResult = sqlite3_step(statement)
        if stepResult == SQLITE_DONE { return nil }
        guard stepResult == SQLITE_ROW else { throw sqliteError() }
        return columnText(statement, 0)
    }

    func searchAttachments(
        matching query: ChatAttachmentHistoryQuery,
        before cursor: ChatAttachmentHistoryCursor?,
        limit: Int,
        completion: @escaping (Result<ChatAttachmentHistoryPage, Error>) -> Void
    ) {
        queue.async {
            do {
                try self.migrateLegacyJSONIfNeeded()
                completion(.success(try self.fetchAttachmentHistory(matching: query, before: cursor, limit: limit)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func searchMessages(
        matching query: ChatHistorySearchQuery,
        before cursor: ChatHistorySearchCursor?,
        limit: Int,
        completion: @escaping (Result<ChatHistorySearchPage, Error>) -> Void
    ) {
        queue.async {
            do {
                try self.migrateLegacyJSONIfNeeded()
                completion(.success(try self.fetchSearchResults(matching: query, before: cursor, limit: limit)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func loadConversationImages(
        for conversationID: String,
        completion: @escaping (Result<[ChatHistoryImage], Error>) -> Void
    ) {
        queue.async {
            completion(Result { try self.fetchConversationImages(for: conversationID) })
        }
    }

    func loadReceivedFiles(
        for peerID: String,
        limit: Int,
        completion: @escaping (Result<[ChatReceivedFile], Error>) -> Void
    ) {
        queue.async {
            do {
                let files = try self.fetchReceivedFiles(
                    for: peerID,
                    limit: limit
                )
                completion(.success(files))
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

                CREATE TABLE IF NOT EXISTS conversation_settings (
                    conversation_id TEXT PRIMARY KEY NOT NULL,
                    settings_json TEXT NOT NULL
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
                    attachments_json TEXT NOT NULL DEFAULT '[]',
                    created_at REAL NOT NULL,
                    FOREIGN KEY(peer_id) REFERENCES conversations(peer_id)
                        ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_messages_peer_time
                    ON messages(peer_id, created_at DESC, id DESC);

                CREATE INDEX IF NOT EXISTS idx_messages_time
                    ON messages(created_at DESC, id DESC);

                CREATE TABLE IF NOT EXISTS deleted_message_images (
                    message_id TEXT NOT NULL,
                    attachment_id TEXT NOT NULL,
                    PRIMARY KEY(message_id, attachment_id),
                    FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS store_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                """
            )
            try ensureConversationKindColumn()
            try ensureMessageAttachmentsColumn()
            try ensurePeerDeviceIdentifierColumn()
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

    private func ensureMessageAttachmentsColumn() throws {
        var hasAttachments = false
        do {
            let statement = try prepare("PRAGMA table_info(messages)")
            defer { sqlite3_finalize(statement) }

            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    break
                }
                guard result == SQLITE_ROW else {
                    throw sqliteError()
                }
                if columnText(statement, 1) == "attachments_json" {
                    hasAttachments = true
                    break
                }
            }
        }

        if !hasAttachments {
            try execute(
                "ALTER TABLE messages ADD COLUMN attachments_json TEXT NOT NULL DEFAULT '[]'"
            )
        }
    }

    private func ensurePeerDeviceIdentifierColumn() throws {
        let statement = try prepare("PRAGMA table_info(conversations)")
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw sqliteError() }
            if columnText(statement, 1) == "device_identifier" { return }
        }
        try execute("ALTER TABLE conversations ADD COLUMN device_identifier TEXT NOT NULL DEFAULT ''")
    }

    private func preparePeerIdentities() throws {
        guard !hasPreparedPeerIdentities else { return }
        try migrateLegacyJSONIfNeeded()
        let peers = try fetchPeers()
        let groups = Dictionary(grouping: peers.filter { PeerIdentity.legacyMergeKey(for: $0.peer) != nil }) {
            PeerIdentity.legacyMergeKey(for: $0.peer)!
        }.values.filter { $0.count > 1 }
        try performTransaction {
            for candidates in groups {
                var earliest: [String: Double] = [:]
                var preferences: [String: ConversationSettings] = [:]
                for candidate in candidates {
                    let dateStatement = try prepare("SELECT MIN(created_at) FROM messages WHERE peer_id = ?")
                    defer { sqlite3_finalize(dateStatement) }
                    try bindText(candidate.peerID, at: 1, in: dateStatement)
                    guard sqlite3_step(dateStatement) == SQLITE_ROW else { throw sqliteError() }
                    earliest[candidate.peerID] = sqlite3_column_type(dateStatement, 0) == SQLITE_NULL
                        ? candidate.peer.lastSeen.timeIntervalSince1970 : sqlite3_column_double(dateStatement, 0)
                    let settingsStatement = try prepare("SELECT settings_json FROM conversation_settings WHERE conversation_id = ?")
                    defer { sqlite3_finalize(settingsStatement) }
                    try bindText(candidate.peerID, at: 1, in: settingsStatement)
                    let status = sqlite3_step(settingsStatement)
                    guard status == SQLITE_ROW || status == SQLITE_DONE else { throw sqliteError() }
                    if status == SQLITE_ROW {
                        preferences[candidate.peerID] = try JSONDecoder().decode(ConversationSettings.self,
                            from: Data(columnText(settingsStatement, 0).utf8)).validated()
                    }
                }
                let ordered = candidates.sorted {
                    let first = earliest[$0.peerID]!, second = earliest[$1.peerID]!
                    return first == second ? $0.peerID < $1.peerID : first < second
                }
                let canonical = ordered[0]
                let latest = ordered.max { $0.peer.lastSeen < $1.peer.lastSeen }!.peer
                var mergedSettings = ConversationSettings()
                var remarks: [String] = []
                for candidate in ordered {
                    let settings = preferences[candidate.peerID] ?? ConversationSettings()
                    mergedSettings.isPinned = mergedSettings.isPinned || settings.isPinned
                    mergedSettings.isMuted = mergedSettings.isMuted || settings.isMuted
                    mergedSettings.isBlocked = mergedSettings.isBlocked || settings.isBlocked
                    mergedSettings.tags += settings.tags
                    if !settings.remark.isEmpty, !remarks.contains(settings.remark) { remarks.append(settings.remark) }
                }
                mergedSettings.remark = remarks.joined(separator: " / ")
                guard let normalizedSettings = try? mergedSettings.validated() else { continue }
                let mergedPeer = FeiQPeer(id: canonical.peerID, name: latest.name, hostName: latest.hostName,
                    ipAddress: latest.ipAddress, group: latest.group, lastSeen: latest.lastSeen,
                    isOnline: false, deviceIdentifier: latest.deviceIdentifier)
                try upsertPeer(mergedPeer)
                for duplicate in ordered.dropFirst() {
                    for sql in [
                        "UPDATE messages SET peer_id = ? WHERE peer_id = ?",
                        "INSERT OR IGNORE INTO chat_group_members(group_id, peer_id, sort_order) SELECT group_id, ?, sort_order FROM chat_group_members WHERE peer_id = ?"
                    ] {
                        let statement = try prepare(sql)
                        defer { sqlite3_finalize(statement) }
                        try bindText(canonical.peerID, at: 1, in: statement)
                        try bindText(duplicate.peerID, at: 2, in: statement)
                        try stepDone(statement)
                    }
                    for sql in ["DELETE FROM chat_group_members WHERE peer_id = ?",
                                "DELETE FROM conversation_settings WHERE conversation_id = ?",
                                "DELETE FROM conversations WHERE peer_id = ?"] {
                        let statement = try prepare(sql)
                        defer { sqlite3_finalize(statement) }
                        try bindText(duplicate.peerID, at: 1, in: statement)
                        try stepDone(statement)
                    }
                }
                let settingsStatement = try prepare("INSERT OR REPLACE INTO conversation_settings(conversation_id, settings_json) VALUES (?, ?)")
                defer { sqlite3_finalize(settingsStatement) }
                try bindText(canonical.peerID, at: 1, in: settingsStatement)
                try bindText(String(decoding: JSONEncoder().encode(normalizedSettings), as: UTF8.self), at: 2, in: settingsStatement)
                try stepDone(settingsStatement)
                let unread = ordered.reduce(0) { min(Int(Int32.max), $0 + max(0, $1.unreadCount)) }
                try updateUnreadCount(normalizedSettings.isBlocked ? 0 : unread, for: canonical.peerID)
            }
        }
        hasPreparedPeerIdentities = true
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
                   last_seen, is_online, unread_count, device_identifier
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
                isOnline: sqlite3_column_int(statement, 6) != 0,
                deviceIdentifier: PeerIdentity.deviceIdentifier(columnText(statement, 8))
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
        after afterMessage: ChatMessage? = nil,
        limit: Int
    ) throws -> ChatHistoryPage {
        let pageSize = max(1, min(limit, 200))
        let statement: OpaquePointer

        let boundary = beforeMessage ?? afterMessage
        if boundary == nil {
            statement = try prepare(
                """
                SELECT id, direction, text, sender_name, recipient_name,
                       attachments_json, created_at
                FROM messages
                WHERE peer_id = ?
                ORDER BY created_at DESC, id DESC
                LIMIT ?
                """
            )
        } else {
            let comparison = afterMessage == nil ? "<" : ">"
            let order = afterMessage == nil ? "DESC" : "ASC"
            statement = try prepare(
                """
                SELECT id, direction, text, sender_name, recipient_name,
                       attachments_json, created_at
                FROM messages
                WHERE peer_id = ?
                  AND (
                      created_at \(comparison) ?
                      OR (created_at = ? AND id \(comparison) ?)
                  )
                ORDER BY created_at \(order), id \(order)
                LIMIT ?
                """
            )
        }
        defer { sqlite3_finalize(statement) }

        try bindText(peerID, at: 1, in: statement)
        if let boundary {
            try bindDouble(boundary.date.timeIntervalSince1970, at: 2, in: statement)
            try bindDouble(boundary.date.timeIntervalSince1970, at: 3, in: statement)
            try bindText(boundary.id.uuidString, at: 4, in: statement)
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
        let page = Array(rows.prefix(pageSize))
        return ChatHistoryPage(
            messages: afterMessage == nil ? Array(page.reversed()) : page,
            hasMore: hasMore
        )
    }

    private func fetchSearchResults(
        matching query: ChatHistorySearchQuery,
        before cursor: ChatHistorySearchCursor?,
        limit: Int
    ) throws -> ChatHistorySearchPage {
        let bounds = try query.dateBounds()
        let pageSize = max(1, min(limit, 200))
        var conditions: [String] = []
        if query.conversationID != nil { conditions.append("messages.peer_id = :conversation") }
        if bounds.start != nil { conditions.append("messages.created_at >= :start") }
        if bounds.end != nil { conditions.append("messages.created_at < :end") }
        if cursor != nil {
            conditions.append("(messages.created_at < :cursorDate OR (messages.created_at = :cursorDate AND messages.id < :cursorID))")
        }

        let attachments = "json_each(CASE WHEN json_valid(messages.attachments_json) THEN messages.attachments_json ELSE '[]' END) AS attachment"
        let attachmentKind = query.kind.attachmentKind.map { " AND json_extract(attachment.value, '$.kind') = '\($0.rawValue)'" } ?? ""
        if query.kind == .text {
            conditions.append("length(trim(messages.text, char(9) || char(10) || char(13) || ' ')) > 0")
        } else if query.kind.attachmentKind != nil {
            conditions.append("EXISTS (SELECT 1 FROM \(attachments) WHERE attachment.type = 'object'\(attachmentKind))")
        }
        if !query.keyword.isEmpty {
            let textMatch = "messages.text LIKE :keyword ESCAPE '\\'"
            if query.kind == .text {
                conditions.append(textMatch)
            } else {
                conditions.append("""
                    (\(textMatch) OR EXISTS (
                        SELECT 1 FROM \(attachments)
                        WHERE attachment.type = 'object'\(attachmentKind)
                          AND json_extract(attachment.value, '$.fileName') LIKE :keyword ESCAPE '\\'
                    ))
                    """)
            }
        }
        let predicate = conditions.isEmpty ? "1 = 1" : conditions.joined(separator: " AND ")
        let statement = try prepare("""
            SELECT messages.id, messages.direction, messages.text, messages.sender_name,
                   messages.recipient_name, messages.attachments_json, messages.created_at,
                   conversations.peer_id, conversations.name, conversations.host_name,
                   conversations.ip_address, conversations.conversation_kind
            FROM messages JOIN conversations ON conversations.peer_id = messages.peer_id
            WHERE \(predicate)
            ORDER BY messages.created_at DESC, messages.id DESC
            LIMIT :pageSize
            """)
        defer { sqlite3_finalize(statement) }
        if let conversationID = query.conversationID {
            try bindText(conversationID, at: sqlite3_bind_parameter_index(statement, ":conversation"), in: statement)
        }
        if let start = bounds.start {
            try bindDouble(start.timeIntervalSince1970, at: sqlite3_bind_parameter_index(statement, ":start"), in: statement)
        }
        if let end = bounds.end {
            try bindDouble(end.timeIntervalSince1970, at: sqlite3_bind_parameter_index(statement, ":end"), in: statement)
        }
        if let cursor {
            try bindDouble(cursor.date.timeIntervalSince1970, at: sqlite3_bind_parameter_index(statement, ":cursorDate"), in: statement)
            try bindText(cursor.messageID.uuidString, at: sqlite3_bind_parameter_index(statement, ":cursorID"), in: statement)
        }
        if !query.keyword.isEmpty {
            let escaped = query.keyword
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            try bindText("%\(escaped)%", at: sqlite3_bind_parameter_index(statement, ":keyword"), in: statement)
        }
        try bindInt32(Int32(pageSize + 1), at: sqlite3_bind_parameter_index(statement, ":pageSize"), in: statement)

        var results: [ChatHistorySearchResult] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else { throw sqliteError() }
            let conversationID = columnText(statement, 7)
            let name = columnText(statement, 8).trimmingCharacters(in: .whitespacesAndNewlines)
            let host = columnText(statement, 9)
            let address = columnText(statement, 10)
            let fallback = host.isEmpty ? (address.isEmpty ? conversationID : address) : host
            results.append(ChatHistorySearchResult(
                conversationID: conversationID, conversationName: name.isEmpty ? fallback : name,
                isGroup: columnText(statement, 11) == "group", message: message(from: statement)
            ))
        }
        return ChatHistorySearchPage(results: Array(results.prefix(pageSize)), hasMore: results.count > pageSize)
    }

    private func fetchAttachmentHistory(
        matching query: ChatAttachmentHistoryQuery,
        before cursor: ChatAttachmentHistoryCursor?,
        limit: Int
    ) throws -> ChatAttachmentHistoryPage {
        let bounds = try query.dateBounds()
        let pageSize = max(1, min(limit, 200))
        let attachmentJSON = "CASE WHEN attachment.type = 'object' THEN attachment.value ELSE '{}' END"
        let remark = "CASE WHEN json_valid(settings.settings_json) THEN json_extract(settings.settings_json, '$.remark') ELSE '' END"
        var conditions = [
            "attachment.type = 'object'",
            "json_extract(\(attachmentJSON), '$.kind') IN ('image', 'file')",
            "messages.direction IN ('incoming', 'outgoing')"
        ]
        if query.conversationID != nil { conditions.append("messages.peer_id = :conversation") }
        if query.direction != nil { conditions.append("messages.direction = :direction") }
        if query.kind != nil { conditions.append("json_extract(\(attachmentJSON), '$.kind') = :kind") }
        if bounds.start != nil { conditions.append("messages.created_at >= :start") }
        if bounds.end != nil { conditions.append("messages.created_at < :end") }
        if cursor != nil {
            conditions.append("""
                (messages.created_at < :cursorDate OR (messages.created_at = :cursorDate AND
                    (messages.id < :cursorID OR (messages.id = :cursorID AND attachment.key > :cursorIndex))))
                """)
        }
        if !query.keyword.isEmpty {
            conditions.append("""
                (json_extract(\(attachmentJSON), '$.fileName') LIKE :keyword ESCAPE '\\'
                    OR messages.sender_name LIKE :keyword ESCAPE '\\'
                    OR conversations.name LIKE :keyword ESCAPE '\\'
                    OR conversations.host_name LIKE :keyword ESCAPE '\\'
                    OR conversations.ip_address LIKE :keyword ESCAPE '\\'
                    OR (\(remark)) LIKE :keyword ESCAPE '\\')
                """)
        }
        let statement = try prepare("""
            SELECT messages.id, messages.direction, messages.sender_name, messages.created_at,
                   \(attachmentJSON), attachment.key, conversations.peer_id, conversations.name,
                   conversations.host_name, conversations.ip_address, conversations.conversation_kind,
                   \(remark)
            FROM messages
            JOIN conversations ON conversations.peer_id = messages.peer_id
            LEFT JOIN conversation_settings AS settings ON settings.conversation_id = messages.peer_id
            JOIN json_each(CASE WHEN json_valid(messages.attachments_json) THEN
                CASE WHEN json_type(messages.attachments_json) = 'array' THEN messages.attachments_json ELSE '[]' END
                ELSE '[]' END) AS attachment
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY messages.created_at DESC, messages.id DESC, attachment.key ASC
            LIMIT :pageSize
            """)
        defer { sqlite3_finalize(statement) }
        for (parameter, value) in [
            (":conversation", query.conversationID), (":direction", query.direction?.rawValue),
            (":kind", query.kind?.rawValue)
        ] {
            if let value { try bindText(value, at: sqlite3_bind_parameter_index(statement, parameter), in: statement) }
        }
        if let start = bounds.start {
            try bindDouble(start.timeIntervalSince1970, at: sqlite3_bind_parameter_index(statement, ":start"), in: statement)
        }
        if let end = bounds.end {
            try bindDouble(end.timeIntervalSince1970, at: sqlite3_bind_parameter_index(statement, ":end"), in: statement)
        }
        if let cursor {
            try bindDouble(cursor.date.timeIntervalSince1970, at: sqlite3_bind_parameter_index(statement, ":cursorDate"), in: statement)
            try bindText(cursor.messageID.uuidString, at: sqlite3_bind_parameter_index(statement, ":cursorID"), in: statement)
            try bindInt32(Int32(clamping: cursor.attachmentIndex), at: sqlite3_bind_parameter_index(statement, ":cursorIndex"), in: statement)
        }
        if !query.keyword.isEmpty {
            let escaped = query.keyword
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            try bindText("%\(escaped)%", at: sqlite3_bind_parameter_index(statement, ":keyword"), in: statement)
        }
        try bindInt32(Int32(pageSize + 1), at: sqlite3_bind_parameter_index(statement, ":pageSize"), in: statement)
        let decoder = JSONDecoder()
        var rows: [(cursor: ChatAttachmentHistoryCursor, result: ChatAttachmentHistoryResult?)] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else { throw sqliteError() }
            guard let messageID = UUID(uuidString: columnText(statement, 0)) else { continue }
            let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            let index = Int(sqlite3_column_int64(statement, 5))
            let rowCursor = ChatAttachmentHistoryCursor(date: date, messageID: messageID, attachmentIndex: index)
            var result: ChatAttachmentHistoryResult?
            if let direction = ChatMessageDirection(rawValue: columnText(statement, 1)),
               let attachment = try? decoder.decode(ChatAttachment.self, from: Data(columnText(statement, 4).utf8)) {
                let conversationID = columnText(statement, 6)
                let name = columnText(statement, 7).trimmingCharacters(in: .whitespacesAndNewlines)
                let host = columnText(statement, 8)
                let address = columnText(statement, 9)
                let fallback = host.isEmpty ? (address.isEmpty ? conversationID : address) : host
                let localRemark = columnText(statement, 11).trimmingCharacters(in: .whitespacesAndNewlines)
                result = ChatAttachmentHistoryResult(
                    conversationID: conversationID,
                    conversationName: localRemark.isEmpty ? (name.isEmpty ? fallback : name) : localRemark,
                    isGroup: columnText(statement, 10) == "group", messageID: messageID,
                    attachment: attachment, attachmentIndex: index, date: date,
                    senderName: columnText(statement, 2), direction: direction
                )
            }
            rows.append((rowCursor, result))
        }
        let page = rows.prefix(pageSize)
        return ChatAttachmentHistoryPage(
            results: page.compactMap(\.result), hasMore: rows.count > pageSize, nextCursor: page.last?.cursor
        )
    }

    private func fetchConversationImages(for conversationID: String) throws -> [ChatHistoryImage] {
        let statement = try prepare(
            """
            SELECT id, direction, sender_name, attachments_json, created_at
            FROM messages
            WHERE peer_id = ? AND attachments_json <> '[]'
            ORDER BY created_at ASC, id ASC
            """
        )
        defer { sqlite3_finalize(statement) }
        try bindText(conversationID, at: 1, in: statement)
        var images: [ChatHistoryImage] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw sqliteError() }
            guard let messageID = UUID(uuidString: columnText(statement, 0)),
                  let direction = ChatMessageDirection(rawValue: columnText(statement, 1)) else { continue }
            let senderName = columnText(statement, 2)
            let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            for (index, attachment) in decodeAttachments(columnText(statement, 3)).enumerated() where attachment.isImage {
                images.append(ChatHistoryImage(
                    messageID: messageID, attachment: attachment, attachmentIndex: index,
                    date: date, senderName: senderName, direction: direction
                ))
            }
        }
        return images
    }

    private func fetchReceivedFiles(
        for peerID: String,
        limit: Int
    ) throws -> [ChatReceivedFile] {
        let pageSize = max(1, min(limit, 200))
        let statement = try prepare(
            """
            SELECT id, sender_name, attachments_json, created_at
            FROM messages
            WHERE peer_id = ?
              AND direction = 'incoming'
              AND attachments_json <> '[]'
            ORDER BY created_at DESC, id DESC
            LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }

        try bindText(peerID, at: 1, in: statement)
        try bindInt32(Int32(pageSize), at: 2, in: statement)

        var files: [ChatReceivedFile] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW else {
                throw sqliteError()
            }

            let messageID = columnText(statement, 0)
            let senderName = columnText(statement, 1)
            let receivedAt = Date(
                timeIntervalSince1970: sqlite3_column_double(statement, 3)
            )
            for attachment in decodeAttachments(columnText(statement, 2)) {
                files.append(
                    ChatReceivedFile(
                        id: messageID + ":" + attachment.id,
                        attachment: attachment,
                        receivedAt: receivedAt,
                        senderName: senderName
                    )
                )
            }
        }
        return files
    }

    private func message(from statement: OpaquePointer) -> ChatMessage {
        ChatMessage(
            id: UUID(uuidString: columnText(statement, 0)) ?? UUID(),
            direction: ChatMessageDirection(rawValue: columnText(statement, 1))
                ?? .incoming,
            text: columnText(statement, 2),
            senderName: columnText(statement, 3),
            recipientName: columnText(statement, 4),
            date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            attachments: decodeAttachments(columnText(statement, 5))
        )
    }

    private func upsertPeer(_ peer: FeiQPeer) throws {
        let statement = try prepare(
            """
            INSERT INTO conversations (
                peer_id, name, host_name, ip_address, group_name,
                last_seen, is_online, unread_count, conversation_kind, device_identifier
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, 'peer', ?)
            ON CONFLICT(peer_id) DO UPDATE SET
                name = excluded.name,
                host_name = excluded.host_name,
                ip_address = excluded.ip_address,
                group_name = excluded.group_name,
                last_seen = excluded.last_seen,
                is_online = excluded.is_online,
                conversation_kind = 'peer',
                device_identifier = CASE WHEN excluded.device_identifier <> '' THEN excluded.device_identifier ELSE conversations.device_identifier END
            WHERE excluded.last_seen >= conversations.last_seen
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
        try bindText(PeerIdentity.deviceIdentifier(peer.deviceIdentifier) ?? "", at: 8, in: statement)
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
        let deleted = try prepare("SELECT attachment_id FROM deleted_message_images WHERE message_id = ?")
        defer { sqlite3_finalize(deleted) }
        try bindText(message.id.uuidString, at: 1, in: deleted)
        var deletedIDs = Set<String>()
        var result = sqlite3_step(deleted)
        while result == SQLITE_ROW {
            deletedIDs.insert(columnText(deleted, 0))
            result = sqlite3_step(deleted)
        }
        guard result == SQLITE_DONE else {
            throw ChatHistoryStoreError.sqlite("无法读取图片删除记录")
        }
        let message = message.removingImages(withIDs: deletedIDs)
        let statement = try prepare(
            """
            INSERT INTO messages (
                id, peer_id, direction, text, sender_name, recipient_name,
                attachments_json, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                text = excluded.text,
                attachments_json = excluded.attachments_json
            WHERE messages.peer_id = excluded.peer_id
            """
        )
        defer { sqlite3_finalize(statement) }

        try bindText(message.id.uuidString, at: 1, in: statement)
        try bindText(conversationID, at: 2, in: statement)
        try bindText(message.direction.rawValue, at: 3, in: statement)
        try bindText(message.text, at: 4, in: statement)
        try bindText(message.senderName, at: 5, in: statement)
        try bindText(message.recipientName, at: 6, in: statement)
        try bindText(encodeAttachments(message.attachments), at: 7, in: statement)
        try bindDouble(message.date.timeIntervalSince1970, at: 8, in: statement)
        try stepDone(statement)
    }

    private func encodeAttachments(_ attachments: [ChatAttachment]) -> String {
        guard let data = try? JSONEncoder().encode(attachments) else {
            return "[]"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeAttachments(_ value: String) -> [ChatAttachment] {
        guard !value.isEmpty,
              let data = value.data(using: .utf8),
              let attachments = try? JSONDecoder().decode(
                [ChatAttachment].self,
                from: data
              ) else {
            return []
        }
        return attachments
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
        guard !restoredDuringThisRun else { throw DatabaseMaintenanceError.restartRequired }
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
        guard !restoredDuringThisRun else { throw DatabaseMaintenanceError.restartRequired }
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
