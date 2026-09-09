import Foundation

protocol ConversationSettingsRepository: AnyObject {
    var snapshot: [String: ConversationSettings] { get }
    var loadError: Error? { get }
    func settings(for conversationID: String) -> ConversationSettings
    func save(_ settings: ConversationSettings, for conversationID: String,
              completion: @escaping (Result<ConversationSettings, Error>) -> Void)
}

final class DefaultConversationSettingsRepository: ConversationSettingsRepository {
    private let historyService: ChatHistoryService
    private let lock = NSLock()
    private var stored: [String: ConversationSettings] = [:]
    private(set) var loadError: Error?

    var snapshot: [String: ConversationSettings] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    init(historyService: ChatHistoryService) {
        self.historyService = historyService
        do { stored = try historyService.loadConversationSettings() }
        catch { loadError = error }
    }

    func settings(for conversationID: String) -> ConversationSettings {
        lock.lock()
        defer { lock.unlock() }
        return stored[conversationID] ?? ConversationSettings()
    }

    func save(_ settings: ConversationSettings, for conversationID: String,
              completion: @escaping (Result<ConversationSettings, Error>) -> Void) {
        do {
            if let loadError { throw loadError }
            guard !conversationID.isEmpty else { throw ConversationSettingsError.unavailable }
            let normalized = try settings.validated()
            historyService.saveConversationSettings(normalized, for: conversationID) { [self] result in
                if case .success = result {
                    lock.lock()
                    stored[conversationID] = normalized.isDefault ? nil : normalized
                    lock.unlock()
                }
                completion(result.map { normalized })
            }
        } catch { completion(.failure(error)) }
    }
}
