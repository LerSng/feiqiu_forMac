import Foundation

protocol ChatHistoryService: AnyObject {
    var locationDescription: String { get }

    func loadSnapshot(
        completion: @escaping (Result<ChatHistorySnapshot, Error>) -> Void
    )
    func loadRecentMessages(
        for peerID: String,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    )
    func loadEarlierMessages(
        for peerID: String,
        before message: ChatMessage,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    )
    func savePeer(_ peer: FeiQPeer)
    func saveMessage(
        _ message: ChatMessage,
        for peer: FeiQPeer,
        unreadCount: Int
    )
    func setUnreadCount(_ count: Int, for peerID: String)
}

final class SQLiteChatHistoryService: ChatHistoryService {
    private let store: ChatHistoryStore

    var locationDescription: String {
        store.locationDescription
    }

    init(store: ChatHistoryStore) {
        self.store = store
    }

    static func makeDefault() -> SQLiteChatHistoryService {
        let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directoryURL = documentsURL.appendingPathComponent(
            "飞秋 Mac",
            isDirectory: true
        )
        let databaseURL = directoryURL.appendingPathComponent(
            "ChatHistory.sqlite",
            isDirectory: false
        )
        let legacyURL = directoryURL.appendingPathComponent(
            "ChatHistory.json",
            isDirectory: false
        )

        return SQLiteChatHistoryService(
            store: ChatHistoryStore(
                databaseURL: databaseURL,
                legacyURL: legacyURL
            )
        )
    }

    func loadSnapshot(
        completion: @escaping (Result<ChatHistorySnapshot, Error>) -> Void
    ) {
        store.loadSnapshot(completion: completion)
    }

    func loadRecentMessages(
        for peerID: String,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    ) {
        store.loadRecentMessages(
            for: peerID,
            limit: limit,
            completion: completion
        )
    }

    func loadEarlierMessages(
        for peerID: String,
        before message: ChatMessage,
        limit: Int,
        completion: @escaping (Result<ChatHistoryPage, Error>) -> Void
    ) {
        store.loadEarlierMessages(
            for: peerID,
            before: message,
            limit: limit,
            completion: completion
        )
    }

    func savePeer(_ peer: FeiQPeer) {
        store.savePeer(peer)
    }

    func saveMessage(
        _ message: ChatMessage,
        for peer: FeiQPeer,
        unreadCount: Int
    ) {
        store.saveMessage(
            message,
            for: peer,
            unreadCount: unreadCount
        )
    }

    func setUnreadCount(_ count: Int, for peerID: String) {
        store.setUnreadCount(count, for: peerID)
    }
}
