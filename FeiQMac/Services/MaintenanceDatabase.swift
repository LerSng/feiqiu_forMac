import Foundation
import SQLite3

protocol DatabaseMaintenanceAccess: AnyObject {
    var maintenanceRequiresRestart: Bool { get }
    func withMaintenanceDatabase<Value>(requiresRestart: Bool,
        operation: @escaping (OpaquePointer, URL) throws -> Value,
        completion: @escaping (Result<Value, Error>) -> Void
    )
}

struct MaintenanceMessageAttachments {
    let messageID: String
    let date: Date
    let attachments: [ChatAttachment]
}

enum MaintenanceDatabase {
    static let tables: [(name: String, columns: [String])] = [
        ("conversations", ["peer_id", "name", "host_name", "ip_address", "group_name", "last_seen", "is_online", "unread_count", "conversation_kind", "device_identifier"]),
        ("conversation_settings", ["conversation_id", "settings_json"]),
        ("chat_groups", ["group_id", "name", "owner_name", "created_at"]),
        ("chat_group_members", ["group_id", "peer_id", "sort_order"]),
        ("messages", ["id", "peer_id", "direction", "text", "sender_name", "recipient_name", "attachments_json", "created_at"]),
        ("deleted_message_images", ["message_id", "attachment_id"]),
        ("store_metadata", ["key", "value"])
    ]

    static func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw error(database) }
    }

    static func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error(database) }
        return statement
    }

    static func rows(_ sql: String, in database: OpaquePointer, body: (OpaquePointer) throws -> Void) throws {
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw error(database) }
            try body(statement)
        }
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    static func bind(_ text: String, at index: Int32, in statement: OpaquePointer) throws {
        let status = text.withCString {
            sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard status == SQLITE_OK else { throw error(sqlite3_db_handle(statement)) }
    }

    static func count(_ table: String, in database: OpaquePointer) throws -> Int {
        var count = 0
        try rows("SELECT count(*) FROM \(table)", in: database) { count = Int(sqlite3_column_int64($0, 0)) }
        return count
    }

    static func attachments(in database: OpaquePointer) throws -> [MaintenanceMessageAttachments] {
        var records: [MaintenanceMessageAttachments] = []
        let decoder = JSONDecoder()
        try rows("SELECT id, created_at, attachments_json, direction FROM messages", in: database) { statement in
            let identifier = text(statement, 0)
            let date = sqlite3_column_double(statement, 1)
            guard UUID(uuidString: identifier) != nil, date.isFinite,
                  ChatMessageDirection(rawValue: text(statement, 3)) != nil else {
                throw DatabaseMaintenanceError.invalidBackup("消息 ID、时间或方向无效")
            }
            let attachments = try decoder.decode([ChatAttachment].self, from: Data(text(statement, 2).utf8))
            guard Set(attachments.map(\.id)).count == attachments.count,
                  attachments.allSatisfy({ !$0.id.isEmpty && $0.fileSize >= 0 && !$0.localPath.contains("\0") }) else {
                throw DatabaseMaintenanceError.invalidBackup("附件元数据无效")
            }
            if !attachments.isEmpty {
                records.append(.init(messageID: identifier, date: Date(timeIntervalSince1970: date), attachments: attachments))
            }
        }
        return records
    }

    static func rewriteAttachments(in database: OpaquePointer, records: [MaintenanceMessageAttachments], paths: [String: String]) throws {
        let statement = try prepare("UPDATE messages SET attachments_json = ? WHERE id = ?", in: database)
        defer { sqlite3_finalize(statement) }
        for record in records {
            let attachments = record.attachments.map { attachment in
                ChatAttachment(id: attachment.id, kind: attachment.kind, fileName: attachment.fileName,
                               fileSize: attachment.fileSize, modifiedAt: attachment.modifiedAt,
                               fileAttributes: attachment.fileAttributes, localPath: paths[attachment.localPath] ?? "",
                               mimeType: attachment.mimeType)
            }
            let json = String(decoding: try JSONEncoder().encode(attachments), as: UTF8.self)
            try bind(json, at: 1, in: statement)
            try bind(record.messageID, at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error(database) }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }

    static func validate(_ database: OpaquePointer) throws {
        try execute("PRAGMA trusted_schema = OFF", in: database)
        var names: Set<String> = []
        try rows("SELECT type, name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'", in: database) { statement in
            let type = text(statement, 0)
            if type == "index" { return }
            guard type == "table", !text(statement, 2).uppercased().contains("VIRTUAL TABLE") else {
                throw DatabaseMaintenanceError.invalidBackup("备份包含不支持的数据库对象")
            }
            names.insert(text(statement, 1))
        }
        guard names == Set(tables.map(\.name)) else { throw DatabaseMaintenanceError.invalidBackup("数据库结构不匹配") }
        for table in tables {
            var columns: Set<String> = []
            try rows("PRAGMA table_info(\(table.name))", in: database) { columns.insert(text($0, 1)) }
            guard columns == Set(table.columns) else { throw DatabaseMaintenanceError.invalidBackup("\(table.name) 表结构不匹配") }
        }
        try rows("PRAGMA quick_check", in: database) {
            guard text($0, 0) == "ok" else { throw DatabaseMaintenanceError.invalidBackup("SQLite 完整性校验失败") }
        }
        try rows("PRAGMA foreign_key_check", in: database) { _ in
            throw DatabaseMaintenanceError.invalidBackup("数据库引用关系损坏")
        }
        try rows("SELECT settings_json FROM conversation_settings", in: database) {
            _ = try JSONDecoder().decode(ConversationSettings.self, from: Data(text($0, 0).utf8)).validated()
        }
    }

    static func open(_ url: URL, readOnly: Bool) throws -> OpaquePointer {
        var database: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            let failure = error(database)
            if let database { sqlite3_close(database) }
            throw failure
        }
        sqlite3_busy_timeout(database, 2000)
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 32 * 1024 * 1024)
        do { try execute("PRAGMA trusted_schema = OFF", in: database) }
        catch { sqlite3_close(database); throw error }
        return database
    }

    static func snapshot(_ source: OpaquePointer, to destination: URL) throws {
        let target = try open(destination, readOnly: false)
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", source, "main") else { throw error(target) }
        var blockedSince: Date?
        var status: Int32
        repeat {
            status = sqlite3_backup_step(backup, 256)
            if status == SQLITE_BUSY || status == SQLITE_LOCKED {
                if blockedSince == nil { blockedSince = Date() }
                if Date().timeIntervalSince(blockedSince!) >= 5 { break }
                Thread.sleep(forTimeInterval: 0.02)
            } else {
                blockedSince = nil
            }
        } while status == SQLITE_OK || status == SQLITE_BUSY || status == SQLITE_LOCKED
        let finished = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finished == SQLITE_OK else { throw error(target) }
        try execute("PRAGMA journal_mode = DELETE", in: target)
    }

    static func replaceContents(of destination: OpaquePointer, from source: OpaquePointer, paths: [String: String]) throws {
        try execute("BEGIN IMMEDIATE", in: destination)
        do {
            for table in tables.reversed() { try execute("DELETE FROM \(table.name)", in: destination) }
            for table in tables {
                let columns = table.columns.joined(separator: ", ")
                let parameters = table.columns.map { _ in "?" }.joined(separator: ", ")
                let insert = try prepare("INSERT INTO \(table.name) (\(columns)) VALUES (\(parameters))", in: destination)
                defer { sqlite3_finalize(insert) }
                try rows("SELECT \(columns) FROM \(table.name)", in: source) { row in
                    for index in table.columns.indices {
                        guard sqlite3_bind_value(insert, Int32(index + 1), sqlite3_column_value(row, Int32(index))) == SQLITE_OK else {
                            throw error(destination)
                        }
                    }
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw error(destination) }
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                }
            }
            try rewriteAttachments(in: destination, records: attachments(in: destination), paths: paths)
            try execute("UPDATE conversations SET is_online = 0; INSERT OR REPLACE INTO store_metadata(key, value) VALUES ('legacy_json_migrated', '1')", in: destination)
            try validate(destination)
            try execute("COMMIT", in: destination)
        } catch {
            try? execute("ROLLBACK", in: destination)
            throw error
        }
    }

    private static func error(_ database: OpaquePointer?) -> DatabaseMaintenanceError {
        .database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库未打开")
    }
}
