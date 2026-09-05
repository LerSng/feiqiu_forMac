import AppKit
import Combine
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var peers: [FeiQPeer] = []
    @Published private(set) var messagesByPeer: [String: [ChatMessage]] = [:]
    @Published private(set) var unreadCountsByPeer: [String: Int] = [:]
    @Published private(set) var isLoadingMessages = false
    @Published private(set) var hasMoreMessages = false
    @Published private(set) var logs: [String] = []
    @Published private(set) var isRunning = false

    @Published var selectedPeerID: String?
    @Published var draft = ""
    @Published var searchText = ""
    @Published var nickname: String
    @Published var hostName: String
    @Published var groupName: String
    @Published var chatLoadAnimationMode: ChatLoadAnimationMode
    @Published var showingSettings = false
    @Published var showingLogs = false

    private let repository: ChatRepository
    private let settingsRepository: AppSettingsRepository
    private var offlineTimer: Timer?
    private var historyRequestGeneration = 0

    private static let messagePageSize = 60
    private static let inMemoryMessageLimit = 240

    var selectedPeer: FeiQPeer? {
        guard let selectedPeerID else { return nil }
        return peers.first(where: { $0.id == selectedPeerID })
    }

    var onlinePeerCount: Int {
        peers.filter(\.isOnline).count
    }

    var filteredPeers: [FeiQPeer] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return peers }
        return peers.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.hostName.localizedCaseInsensitiveContains(query)
                || $0.ipAddress.localizedCaseInsensitiveContains(query)
                || $0.group.localizedCaseInsensitiveContains(query)
        }
    }

    init(
        repository: ChatRepository,
        settingsRepository: AppSettingsRepository
    ) {
        self.repository = repository
        self.settingsRepository = settingsRepository

        let settings = settingsRepository.load()
        nickname = settings.identity.nickname
        hostName = settings.identity.hostName
        groupName = settings.identity.groupName
        chatLoadAnimationMode = settings.chatLoadAnimationMode

        repository.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event)
            }
        }

        loadHistory()
        startNetwork()
        offlineTimer = Timer.scheduledTimer(
            withTimeInterval: 5,
            repeats: true
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.markOfflinePeers()
            }
        }
    }

    deinit {
        offlineTimer?.invalidate()
        repository.stop()
    }

    func messages(for peerID: String) -> [ChatMessage] {
        messagesByPeer[peerID] ?? []
    }

    func unreadCount(for peerID: String) -> Int {
        max(0, unreadCountsByPeer[peerID] ?? 0)
    }

    func selectPeer(_ peerID: String?) {
        activatePeer(peerID, markRead: true)
    }

    func markMessagesRead(for peerID: String) {
        guard unreadCount(for: peerID) > 0 else { return }
        unreadCountsByPeer[peerID] = nil
        repository.setUnreadCount(0, for: peerID)
    }

    func loadEarlierMessages(
        for peerID: String,
        before message: ChatMessage,
        completion: (() -> Void)? = nil
    ) {
        guard selectedPeerID == peerID,
              hasMoreMessages,
              !isLoadingMessages else {
            return
        }

        isLoadingMessages = true
        let requestGeneration = historyRequestGeneration
        repository.loadEarlierMessages(
            for: peerID,
            before: message,
            limit: Self.messagePageSize
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.selectedPeerID == peerID,
                      self.historyRequestGeneration == requestGeneration else {
                    return
                }

                switch result {
                case .success(let page):
                    let currentMessages = self.messagesByPeer[peerID] ?? []
                    self.messagesByPeer[peerID] = self.mergeMessages(
                        page.messages,
                        with: currentMessages
                    )
                    self.hasMoreMessages = page.hasMore
                    completion?()
                case .failure(let error):
                    self.appendLog("更早聊天记录读取失败：\(error.localizedDescription)")
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.selectedPeerID == peerID,
                          self.historyRequestGeneration == requestGeneration else {
                        return
                    }
                    self.isLoadingMessages = false
                }
            }
        }
    }

    func startNetwork() {
        repository.start(identity: currentIdentity)
    }

    func stopNetwork() {
        repository.stop()
        isRunning = false
    }

    func refreshDiscovery() {
        repository.refreshDiscovery()
        appendLog("手动发送局域网发现广播")
    }

    func saveSettings() {
        nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        hostName = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        groupName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        if nickname.isEmpty { nickname = "飞秋 Mac" }
        if hostName.isEmpty { hostName = Self.defaultHostName }

        settingsRepository.save(
            AppSettings(
                identity: currentIdentity,
                chatLoadAnimationMode: chatLoadAnimationMode
            )
        )
        repository.updateIdentity(currentIdentity)
        repository.announce()
        appendLog("已保存本机资料，并刷新上线信息")
    }

    func sendDraft() {
        guard let peer = selectedPeer else { return }
        let displayText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayText.isEmpty else { return }

        let message = ChatMessage(
            direction: .outgoing,
            text: displayText,
            senderName: nickname,
            recipientName: peer.displayName
        )
        appendMessageToCurrentConversation(message, peerID: peer.id)
        repository.sendMessage(
            message,
            to: peer,
            unreadCount: unreadCount(for: peer.id)
        )
        draft = ""
    }

    func insertEmoji(_ emoji: String) {
        draft.append(emoji)
    }

    func clearLogs() {
        logs.removeAll()
    }

    private var currentIdentity: FeiQIdentity {
        FeiQIdentity(
            nickname: nickname,
            hostName: hostName,
            groupName: groupName
        )
    }

    private func handle(_ event: ChatRepositoryEvent) {
        switch event {
        case .peerUpdated(let peer):
            mergePeer(peer)
            if selectedPeerID == nil, peer.isOnline {
                activatePeer(peer.id, markRead: false)
            }

        case .messageReceived(let message, let peer):
            let isViewing = isViewingConversation(for: peer)
            appendMessageToCurrentConversation(message, peerID: peer.id)
            if !isViewing {
                unreadCountsByPeer[peer.id, default: 0] += 1
            }
            repository.persistMessage(
                message,
                for: peer,
                unreadCount: unreadCount(for: peer.id)
            )
            if !isViewing {
                repository.notifyIncomingMessage(text: message.text, from: peer)
            }

        case .networkStateChanged(let running):
            isRunning = running

        case .log(let message):
            appendLog(message)

        case .notificationSelected(let peerID):
            selectPeer(peerID)
        }
    }

    private func activatePeer(_ peerID: String?, markRead: Bool) {
        if selectedPeerID == peerID {
            if markRead, let peerID {
                markMessagesRead(for: peerID)
            }
            return
        }

        selectedPeerID = peerID
        messagesByPeer.removeAll()
        historyRequestGeneration += 1
        isLoadingMessages = false
        hasMoreMessages = false

        guard let peerID else { return }

        if markRead {
            markMessagesRead(for: peerID)
        }
        loadRecentMessages(for: peerID)
    }

    private func loadRecentMessages(for peerID: String) {
        isLoadingMessages = true
        let requestGeneration = historyRequestGeneration
        repository.loadRecentMessages(
            for: peerID,
            limit: Self.messagePageSize
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.selectedPeerID == peerID,
                      self.historyRequestGeneration == requestGeneration else {
                    return
                }

                switch result {
                case .success(let page):
                    let liveMessages = self.messagesByPeer[peerID] ?? []
                    self.messagesByPeer[peerID] = self.mergeMessages(
                        page.messages,
                        with: liveMessages
                    )
                    self.hasMoreMessages = page.hasMore
                case .failure(let error):
                    self.appendLog("聊天记录读取失败：\(error.localizedDescription)")
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.selectedPeerID == peerID,
                          self.historyRequestGeneration == requestGeneration else {
                        return
                    }
                    self.isLoadingMessages = false
                }
            }
        }
    }

    private func appendMessageToCurrentConversation(
        _ message: ChatMessage,
        peerID: String
    ) {
        guard selectedPeerID == peerID else { return }

        var currentMessages = messagesByPeer[peerID] ?? []
        currentMessages.append(message)
        if currentMessages.count > Self.inMemoryMessageLimit {
            currentMessages.removeFirst(
                currentMessages.count - Self.inMemoryMessageLimit
            )
            hasMoreMessages = true
        }
        messagesByPeer[peerID] = currentMessages
    }

    private func mergeMessages(
        _ first: [ChatMessage],
        with second: [ChatMessage]
    ) -> [ChatMessage] {
        var messagesByID: [UUID: ChatMessage] = [:]
        for message in first + second {
            messagesByID[message.id] = message
        }
        return messagesByID.values.sorted { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date < rhs.date
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func loadHistory() {
        repository.loadSnapshot { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                switch result {
                case .success(let snapshot):
                    let restoredPeers = snapshot.peers.map { storedPeer in
                        var peer = storedPeer
                        // Presence is only valid for the current process lifetime.
                        peer.isOnline = false
                        return peer
                    }
                    self.repository.restorePeers(restoredPeers)
                    self.mergeRestoredPeers(restoredPeers)

                    var unreadCounts = snapshot.unreadCountsByPeer
                    // Preserve messages that arrived while the background snapshot
                    // was being read.
                    for (peerID, count) in self.unreadCountsByPeer {
                        unreadCounts[peerID] = max(count, unreadCounts[peerID] ?? 0)
                    }
                    self.unreadCountsByPeer = unreadCounts
                    self.appendLog(
                        "已加载 \(snapshot.totalMessageCount) 条聊天记录，采用 SQLite 分页存储：\(self.repository.historyLocationDescription)"
                    )
                    if let selectedPeerID = self.selectedPeerID,
                       self.messages(for: selectedPeerID).isEmpty,
                       !self.isLoadingMessages {
                        self.loadRecentMessages(for: selectedPeerID)
                    }

                case .failure(let error):
                    self.appendLog("聊天记录数据库读取失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func mergePeer(_ peer: FeiQPeer) {
        if let index = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[index] = peer
        } else {
            peers.append(peer)
        }
        sortPeers()
    }

    private func mergeRestoredPeers(_ restoredPeers: [FeiQPeer]) {
        var mergedPeers = Dictionary(
            uniqueKeysWithValues: restoredPeers.map { ($0.id, $0) }
        )
        for livePeer in peers {
            if let storedPeer = mergedPeers[livePeer.id] {
                mergedPeers[livePeer.id] = livePeer.isOnline ? livePeer : storedPeer
            } else {
                mergedPeers[livePeer.id] = livePeer
            }
        }
        peers = Array(mergedPeers.values)
        sortPeers()
    }

    private func markOfflinePeers() {
        repository.markOfflinePeers(
            before: Date().addingTimeInterval(-75)
        )
    }

    private func isViewingConversation(for peer: FeiQPeer) -> Bool {
        NSApp.isActive && selectedPeerID == peer.id
    }

    private func sortPeers() {
        peers.sort {
            if $0.isOnline != $1.isOnline {
                return $0.isOnline && !$1.isOnline
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func appendLog(_ message: String) {
        logs.append(message)
        if logs.count > 300 {
            logs.removeFirst(logs.count - 300)
        }
    }

    private static var defaultHostName: String {
        if let localizedName = Host.current().localizedName,
           !localizedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return localizedName
        }
        return ProcessInfo.processInfo.hostName
    }
}
