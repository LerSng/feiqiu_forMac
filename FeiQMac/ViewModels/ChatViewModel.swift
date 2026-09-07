import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var peers: [FeiQPeer] = []
    @Published private(set) var groups: [ChatGroup] = []
    @Published private(set) var messagesByPeer: [String: [ChatMessage]] = [:]
    @Published private(set) var receivedFilesByConversation: [String: [ChatReceivedFile]] = [:]
    @Published private(set) var unreadCountsByPeer: [String: Int] = [:]
    @Published private(set) var isLoadingMessages = false
    @Published private(set) var hasMoreMessages = false
    @Published private(set) var logs: [String] = []
    @Published private(set) var isRunning = false
    @Published private(set) var typingPeerIDs: Set<String> = []

    @Published var selectedPeerID: String?
    @Published var selectedGroupID: String?
    @Published var draft = ""
    @Published private(set) var draftAttachments: [ChatAttachment] = []
    @Published private(set) var pendingImageCount = 0
    @Published var imageSelectionError: String?
    @Published private(set) var isPreparingAttachment = false
    @Published private(set) var isCapturingScreenshot = false
    @Published var searchText = ""
    @Published var nickname: String
    @Published var hostName: String
    @Published var groupName: String
    @Published var chatLoadAnimationMode: ChatLoadAnimationMode
    @Published var showingSettings = false
    @Published private(set) var windowShakeID = UUID()
    @Published private(set) var shakeCoolingDown = false
    @Published var remoteAssistanceRequest: FeiQRemoteAssistanceRequest?

    @Published var showingLogs = false
    @Published var imageDeletionError: String?
    @Published var showingGroupEditor = false
    @Published var editingGroupID: String?

    private let repository: ChatRepository
    private let settingsRepository: AppSettingsRepository
    private var offlineTimer: Timer?
    private var historyRequestGeneration = 0
    private var historyMessageUpdates: [UUID: ChatMessage] = [:]
    private var deletedImageIDsByMessage: [UUID: Set<String>] = [:]
    private var deletingImageKeys = Set<String>()
    private var imagePreparationGeneration = UUID()
    private var typingTimers: [String: DispatchWorkItem] = [:]
    private var localTypingPeerID: String?
    private var localTypingStopWorkItem: DispatchWorkItem?

    private static let messagePageSize = 60
    private static let inMemoryMessageLimit = 240

    var isPreparingPastedImage: Bool { pendingImageCount > 0 }
    var draftImageCount: Int { draftAttachments.filter(\.isImage).count }
    var maximumAlbumImageCount: Int { ChatAttachmentGroup.maximumImageCount }

    func attachmentGroups(for message: ChatMessage) -> [ChatAttachmentGroup] {
        ChatAttachmentGroup.makeGroups(from: message.attachments)
    }

    var canSendShake: Bool {
        isRunning && selectedPeer?.isOnline == true && !shakeCoolingDown
    }

    var compatibleEmoticons: [FeiQMessageFormatter.CompatibleEmoticon] {
        FeiQMessageFormatter.compatibleEmoticons
    }

    func sendShake() {
        guard canSendShake, let peer = selectedPeer else { return }
        shakeCoolingDown = true
        repository.sendShake(to: peer)
        let message = ChatMessage(
            direction: .outgoing, text: "你向对方发送了抖一抖",
            senderName: nickname, recipientName: peer.displayName
        )
        appendMessageToCurrentConversation(message, conversationID: peer.id)
        repository.persistMessage(message, for: peer, unreadCount: unreadCount(for: peer.id))
        windowShakeID = UUID()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.shakeCoolingDown = false
        }
    }

    var selectedPeer: FeiQPeer? {
        guard selectedGroupID == nil else { return nil }
        guard let selectedPeerID else { return nil }
        return peers.first(where: { $0.id == selectedPeerID })
    }

    var selectedGroup: ChatGroup? {
        guard let selectedGroupID else { return nil }
        return groups.first(where: { $0.id == selectedGroupID })
    }

    var selectedConversationID: String? {
        selectedGroupID ?? selectedPeerID
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

    var filteredGroups: [ChatGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.ownerName.localizedCaseInsensitiveContains(query)
                || $0.memberIDs.contains { memberID in
                    peers.first(where: { $0.id == memberID })?.displayName
                        .localizedCaseInsensitiveContains(query) == true
                }
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

    func messages(for conversationID: String) -> [ChatMessage] {
        messagesByPeer[conversationID] ?? []
    }

    func receivedFiles(for conversationID: String) -> [ChatReceivedFile] {
        receivedFilesByConversation[conversationID] ?? []
    }

    func unreadCount(for conversationID: String) -> Int {
        max(0, unreadCountsByPeer[conversationID] ?? 0)
    }

    func isPeerTyping(_ peerID: String) -> Bool {
        typingPeerIDs.contains(peerID)
    }

    /// Starts or refreshes the local typing notification for the selected
    /// peer. The stop packet is debounced so Windows FeiQ does not receive a
    /// start/stop pair for every keystroke.
    func draftDidChange() {
        guard let peer = selectedPeer else {
            stopLocalTyping()
            return
        }

        guard !draft.isEmpty || !draftAttachments.isEmpty else {
            stopLocalTyping()
            return
        }

        if localTypingPeerID != peer.id {
            stopLocalTyping()
            localTypingPeerID = peer.id
            repository.updateTyping(isTyping: true, for: peer)
        }

        localTypingStopWorkItem?.cancel()
        let stopWorkItem = DispatchWorkItem { [weak self] in
            self?.stopLocalTyping()
        }
        localTypingStopWorkItem = stopWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: stopWorkItem)
    }

    func stopLocalTyping() {
        localTypingStopWorkItem?.cancel()
        localTypingStopWorkItem = nil

        guard let peerID = localTypingPeerID else { return }
        localTypingPeerID = nil
        guard let peer = peers.first(where: { $0.id == peerID }) else { return }
        repository.updateTyping(isTyping: false, for: peer)
    }

    func selectPeer(_ peerID: String?) {
        activateConversation(peerID: peerID, groupID: nil, markRead: true)
    }

    func selectGroup(_ groupID: String?) {
        activateConversation(peerID: nil, groupID: groupID, markRead: true)
    }

    func markMessagesRead(for conversationID: String) {
        guard unreadCount(for: conversationID) > 0 else { return }
        unreadCountsByPeer[conversationID] = nil
        repository.setUnreadCount(0, for: conversationID)
    }

    func group(withID groupID: String) -> ChatGroup? {
        groups.first(where: { $0.id == groupID })
    }

    func members(for groupID: String) -> [FeiQPeer] {
        guard let group = group(withID: groupID) else { return [] }
        return group.memberIDs.compactMap { memberID in
            peers.first(where: { $0.id == memberID })
        }
    }

    func openGroupEditor(for groupID: String? = nil) {
        editingGroupID = groupID
        showingGroupEditor = true
    }

    func saveGroup(name: String, memberIDs: [String], editingGroupID: String?) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }

        let normalizedMemberIDs = memberIDs.filter { memberID in
            peers.contains(where: { $0.id == memberID })
        }
        guard !normalizedMemberIDs.isEmpty else { return }

        let group: ChatGroup
        if let editingGroupID,
           let existingGroup = self.group(withID: editingGroupID) {
            group = ChatGroup(
                id: existingGroup.id,
                name: normalizedName,
                memberIDs: normalizedMemberIDs,
                ownerName: existingGroup.ownerName,
                createdAt: existingGroup.createdAt
            )
            if let index = groups.firstIndex(where: { $0.id == existingGroup.id }) {
                groups[index] = group
            }
        } else {
            group = ChatGroup(
                name: normalizedName,
                memberIDs: normalizedMemberIDs,
                ownerName: nickname
            )
            groups.append(group)
        }

        sortGroups()
        repository.saveGroup(group)
        selectGroup(group.id)
        self.editingGroupID = nil
        self.showingGroupEditor = false
    }

    func deleteGroup(_ groupID: String) {
        if selectedGroupID == groupID {
            selectPeer(nil)
        }
        groups.removeAll { $0.id == groupID }
        unreadCountsByPeer.removeValue(forKey: groupID)
        repository.deleteGroup(groupID)
    }

    func loadEarlierMessages(
        for conversationID: String,
        before message: ChatMessage,
        completion: (() -> Void)? = nil
    ) {
        guard selectedConversationID == conversationID,
              hasMoreMessages,
              !isLoadingMessages else {
            return
        }

        historyMessageUpdates.removeAll()
        isLoadingMessages = true
        let requestGeneration = historyRequestGeneration
        repository.loadEarlierMessages(
            for: conversationID,
            before: message,
            limit: Self.messagePageSize
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.selectedConversationID == conversationID,
                      self.historyRequestGeneration == requestGeneration else {
                    return
                }

                switch result {
                case .success(let page):
                    let currentMessages = self.messagesByPeer[conversationID] ?? []
                    self.messagesByPeer[conversationID] = self.mergeMessages(
                        page.messages.map { self.historyMessageUpdates[$0.id] ?? $0 },
                        with: currentMessages
                    )
                    self.hasMoreMessages = page.hasMore
                    completion?()
                case .failure(let error):
                    self.appendLog("更早聊天记录读取失败：\(error.localizedDescription)")
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.selectedConversationID == conversationID,
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

    func setOnlineStatus(_ isOnline: Bool) {
        if isOnline {
            if isRunning {
                repository.announce()
            } else {
                startNetwork()
            }
            appendLog("已切换为在线状态")
        } else {
            stopNetwork()
            appendLog("已切换为离线状态")
        }
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
        let displayText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = draftAttachments
        guard !isPreparingPastedImage,
              !isPreparingAttachment,
              !isCapturingScreenshot,
              !displayText.isEmpty || !attachments.isEmpty else { return }

        guard draftImageCount <= maximumAlbumImageCount else {
            imageSelectionError = "每条消息最多合并发送 \(maximumAlbumImageCount) 张照片，请移除多余照片后发送。"
            return
        }

        stopLocalTyping()

        if let peer = selectedPeer {
            let message = ChatMessage(
                direction: .outgoing,
                text: displayText,
                senderName: nickname,
                recipientName: peer.displayName,
                attachments: attachments
            )
            appendMessageToCurrentConversation(message, conversationID: peer.id)
            repository.sendMessage(
                message,
                to: peer,
                unreadCount: unreadCount(for: peer.id)
            )
        } else if let group = selectedGroup {
            let message = ChatMessage(
                direction: .outgoing,
                text: displayText,
                senderName: nickname,
                recipientName: group.displayName,
                attachments: attachments
            )
            appendMessageToCurrentConversation(message, conversationID: group.id)
            repository.sendGroupMessage(
                message,
                to: group,
                members: members(for: group.id)
            )
        } else {
            return
        }

        draft = ""
        draftAttachments.removeAll()
    }

    func insertEmoji(_ emoji: String) {
        draft.append(emoji)
    }

    func pasteImage(_ data: Data, suggestedFileName: String?) {
        guard reserveImageSlots(1) else { return }
        let generation = imagePreparationGeneration
        repository.preparePastedImage(
            data: data,
            suggestedFileName: suggestedFileName
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.finishPreparingImage(result, generation: generation)
            }
        }
    }

    private func reserveImageSlots(_ count: Int) -> Bool {
        guard selectedConversationID != nil, count > 0 else { return false }
        let available = maximumAlbumImageCount - draftImageCount - pendingImageCount
        guard count <= available else {
            imageSelectionError = "每条消息最多合并 \(maximumAlbumImageCount) 张照片，当前还可添加 \(max(0, available)) 张。"
            return false
        }
        imageSelectionError = nil
        pendingImageCount += count
        return true
    }

    private func finishPreparingImage(_ result: Result<ChatAttachment, Error>, generation: UUID) {
        guard generation == imagePreparationGeneration, selectedConversationID != nil else {
            if case .success(let attachment) = result {
                repository.deleteDraftImage(attachment) { _ in }
            }
            return
        }
        pendingImageCount = max(0, pendingImageCount - 1)
        switch result {
        case .success(let attachment):
            draftAttachments.append(attachment)
            draftDidChange()
        case .failure(let error):
            imageSelectionError = "图片添加失败：\(error.localizedDescription)"
            appendLog(imageSelectionError ?? "图片添加失败")
        }
    }

    /// Opens the native macOS area-selection overlay. The captured PNG is
    /// passed through the same attachment pipeline as a pasted image, so it
    /// appears in the draft area and is persisted only after sending.
    func captureScreenshot() {
        guard selectedConversationID != nil, !isCapturingScreenshot else { return }

        isCapturingScreenshot = true
        repository.captureScreenshot { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCapturingScreenshot = false

                switch result {
                case .success(let data):
                    self.pasteImage(data, suggestedFileName: "screenshot.png")
                case .failure(let error):
                    if let screenshotError = error as? ScreenshotCaptureError,
                       case .cancelled = screenshotError {
                        return
                    }
                    self.appendLog("截屏失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func removeDraftAttachment(_ attachmentID: String) {
        guard let attachment = draftAttachments.first(where: { $0.id == attachmentID }) else { return }
        guard attachment.isImage else {
            draftAttachments.removeAll { $0.id == attachmentID }
            return
        }
        draftAttachments.removeAll { $0.id == attachmentID }
        repository.deleteDraftImage(attachment) { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let error) = result {
                    self?.imageDeletionError = "草稿已移除，但本地图片清理失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func deleteImage(_ attachmentID: String, from message: ChatMessage, conversationID: String) {
        let key = message.id.uuidString + ":" + attachmentID
        guard deletingImageKeys.insert(key).inserted else { return }
        repository.deleteImage(
            attachmentID: attachmentID, messageID: message.id, conversationID: conversationID
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.deletingImageKeys.remove(key)
                switch result {
                case .success(let updated):
                    self.deletedImageIDsByMessage[message.id, default: []].insert(attachmentID)
                    if let index = self.messagesByPeer[conversationID]?.firstIndex(where: { $0.id == message.id }) {
                        self.messagesByPeer[conversationID]?[index] = updated
                    }
                    if self.selectedConversationID == conversationID {
                        self.historyMessageUpdates[message.id] = updated
                    }
                    self.receivedFilesByConversation[conversationID]?.removeAll { $0.id == key }
                case .failure(let error):
                    self.deletedImageIDsByMessage[message.id]?.remove(attachmentID)
                    self.imageDeletionError = error.localizedDescription
                    self.appendLog("删除图片失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func chooseAndAddImages() {
        guard selectedConversationID != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "添加照片"
        panel.message = "最多合并发送 \(maximumAlbumImageCount) 张照片，添加后点击发送"
        guard panel.runModal() == .OK, reserveImageSlots(panel.urls.count) else { return }
        let generation = imagePreparationGeneration
        for fileURL in panel.urls {
            repository.prepareOutgoingImage(from: fileURL) { [weak self] result in
                DispatchQueue.main.async {
                    self?.finishPreparingImage(result, generation: generation)
                }
            }
        }
    }

    /// Adds regular files to the composer. They are copied into the managed
    /// Documents/飞秋 Mac/Files directory before the user presses Send, so a
    /// later network transfer does not depend on the original picker URL.
    func chooseAndAddFiles() {
        guard selectedConversationID != nil else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.item]
        panel.prompt = "添加文件"
        panel.message = "选择要发送的文件"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            return
        }

        isPreparingAttachment = true
        prepareNextOutgoingFile(panel.urls, index: 0)
    }

    private func prepareNextOutgoingFile(_ urls: [URL], index: Int) {
        guard index < urls.count else {
            isPreparingAttachment = false
            draftDidChange()
            return
        }

        repository.prepareOutgoingFile(from: urls[index]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                guard self.selectedConversationID != nil else {
                    self.isPreparingAttachment = false
                    return
                }

                switch result {
                case .success(let attachment):
                    self.draftAttachments.append(attachment)
                case .failure(let error):
                    self.appendLog("文件准备失败：\(error.localizedDescription)")
                }

                self.prepareNextOutgoingFile(urls, index: index + 1)
            }
        }
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

    private func receiveDirectMessage(_ message: ChatMessage, from peer: FeiQPeer, isShake: Bool = false) {
        let isViewing = isViewingConversation(for: peer)
        appendMessageToCurrentConversation(message, conversationID: peer.id)
        appendReceivedFiles(
            from: message,
            conversationID: peer.id,
            senderName: peer.displayName
        )
        if !isViewing {
            unreadCountsByPeer[peer.id, default: 0] += 1
        }
        repository.persistMessage(
            message,
            for: peer,
            unreadCount: unreadCount(for: peer.id)
        )
        let belongsToGroup = groups.contains { group in
            group.memberIDs.contains(peer.id)
        }
        if !isViewing, isShake || !belongsToGroup {
            repository.notifyIncomingMessage(
                text: notificationPreview(for: message),
                from: peer.displayName,
                conversationID: peer.id
            )
        }
    }

    private func handle(_ event: ChatRepositoryEvent) {
        switch event {
        case .peerShook(let peer):
            mergePeer(peer)
            let message = ChatMessage(
                direction: .incoming, text: "对方向你发送了抖一抖",
                senderName: peer.displayName, recipientName: nickname
            )
            receiveDirectMessage(message, from: peer, isShake: true)
            windowShakeID = UUID()

        case .remoteAssistanceRequested(let request):
            mergePeer(request.peer)
            remoteAssistanceRequest = request
            appendLog(
                "收到 \(request.peer.displayName) 的远程协助请求（0xB0），已等待用户确认"
            )

        case .peerUpdated(let peer):
            mergePeer(peer)
            if selectedConversationID == nil, peer.isOnline {
                selectPeer(peer.id)
            }

        case .peerTyping(let peer, let isTyping):
            typingTimers[peer.id]?.cancel()
            typingTimers.removeValue(forKey: peer.id)
            if isTyping {
                typingPeerIDs.insert(peer.id)
                let clearWorkItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.typingPeerIDs.remove(peer.id)
                    self.typingTimers.removeValue(forKey: peer.id)
                }
                typingTimers[peer.id] = clearWorkItem
                // UDP can drop the explicit input-end packet. Clearing stale
                // state keeps the header correct even with older FeiQ builds.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: clearWorkItem)
            } else {
                typingPeerIDs.remove(peer.id)
            }

        case .messageReceived(let message, let peer):
            receiveDirectMessage(message, from: peer)

        case .messageUpdated(let message, let peer):
            let message = message.removingImages(withIDs: deletedImageIDsByMessage[message.id] ?? [])
            // Completing an existing image is not a new incoming message:
            // keep its position, timestamp, unread count and notification.
            if let index = messagesByPeer[peer.id]?.firstIndex(where: { $0.id == message.id }) {
                messagesByPeer[peer.id]?[index] = message
            }
            if isLoadingMessages, selectedConversationID == peer.id {
                historyMessageUpdates[message.id] = message
            }
            appendReceivedFiles(from: message, conversationID: peer.id, senderName: peer.displayName)
            repository.persistMessage(message, for: peer, unreadCount: unreadCount(for: peer.id))

        case .groupMessageReceived(let message, let group):
            if !groups.contains(where: { $0.id == group.id }) {
                groups.append(group)
                sortGroups()
            }

            let isViewing = NSApp.isActive && selectedGroupID == group.id
            appendMessageToCurrentConversation(
                message,
                conversationID: group.id
            )
            appendReceivedFiles(
                from: message,
                conversationID: group.id,
                senderName: message.senderName
            )
            if !isViewing {
                unreadCountsByPeer[group.id, default: 0] += 1
            }
            repository.persistGroupMessage(
                message,
                for: group,
                unreadCount: unreadCount(for: group.id)
            )
            if !isViewing {
                let sender = message.senderName.isEmpty ? group.displayName : message.senderName
                repository.notifyIncomingMessage(
                    text: notificationPreview(for: message),
                    from: group.displayName + " · " + sender,
                    conversationID: group.id
                )
            }

        case .networkStateChanged(let running):
            isRunning = running

        case .log(let message):
            appendLog(message)

        case .notificationSelected(let conversationID):
            selectConversation(conversationID)
        }
    }

    func dismissRemoteAssistanceRequest() {
        remoteAssistanceRequest = nil
    }

    func showRemoteAssistanceLogs() {
        remoteAssistanceRequest = nil
        showingLogs = true
    }

    private func selectConversation(_ conversationID: String) {
        if groups.contains(where: { $0.id == conversationID }) {
            selectGroup(conversationID)
        } else {
            selectPeer(conversationID)
        }
    }

    private func activateConversation(
        peerID: String?,
        groupID: String?,
        markRead: Bool
    ) {
        if selectedPeerID == peerID, selectedGroupID == groupID {
            if markRead, let conversationID = groupID ?? peerID {
                markMessagesRead(for: conversationID)
            }
            return
        }

        selectedPeerID = peerID
        selectedGroupID = groupID
        stopLocalTyping()
        draft = ""
        draftAttachments.removeAll()
        imagePreparationGeneration = UUID()
        pendingImageCount = 0
        imageSelectionError = nil
        isPreparingAttachment = false
        isCapturingScreenshot = false
        messagesByPeer.removeAll()
        historyMessageUpdates.removeAll()
        historyRequestGeneration += 1
        isLoadingMessages = false
        hasMoreMessages = false

        guard let conversationID = groupID ?? peerID else { return }
        receivedFilesByConversation[conversationID] = []

        if markRead {
            markMessagesRead(for: conversationID)
        }
        loadRecentMessages(for: conversationID)
        loadReceivedFiles(for: conversationID)
    }

    private func loadRecentMessages(for conversationID: String) {
        historyMessageUpdates.removeAll()
        isLoadingMessages = true
        let requestGeneration = historyRequestGeneration
        repository.loadRecentMessages(
            for: conversationID,
            limit: Self.messagePageSize
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.selectedConversationID == conversationID,
                      self.historyRequestGeneration == requestGeneration else {
                    return
                }

                switch result {
                case .success(let page):
                    let liveMessages = self.messagesByPeer[conversationID] ?? []
                    self.messagesByPeer[conversationID] = self.mergeMessages(
                        page.messages.map { self.historyMessageUpdates[$0.id] ?? $0 },
                        with: liveMessages
                    )
                    self.hasMoreMessages = page.hasMore
                case .failure(let error):
                    self.appendLog("聊天记录读取失败：\(error.localizedDescription)")
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.selectedConversationID == conversationID,
                          self.historyRequestGeneration == requestGeneration else {
                        return
                    }
                    self.isLoadingMessages = false
                }
            }
        }
    }

    private func loadReceivedFiles(for conversationID: String) {
        let requestGeneration = historyRequestGeneration
        repository.loadReceivedFiles(
            for: conversationID,
            limit: 120
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.selectedConversationID == conversationID,
                      self.historyRequestGeneration == requestGeneration else {
                    return
                }
                switch result {
                case .success(let files):
                    // Do not overwrite attachments received while this
                    // asynchronous history query was in flight.
                    let liveFiles = self.receivedFilesByConversation[conversationID] ?? []
                    let visibleFiles = files.filter { file in
                        !self.deletedImageIDsByMessage.contains { messageID, imageIDs in
                            file.id == messageID.uuidString + ":" + file.attachment.id
                                && imageIDs.contains(file.attachment.id)
                        }
                    }
                    var byID = Dictionary(uniqueKeysWithValues: visibleFiles.map { ($0.id, $0) })
                    for file in liveFiles { byID[file.id] = file }
                    self.receivedFilesByConversation[conversationID] = Array(byID.values.sorted {
                        $0.receivedAt == $1.receivedAt
                            ? $0.id < $1.id : $0.receivedAt > $1.receivedAt
                    }.prefix(120))
                case .failure(let error):
                    self.appendLog("接收文件列表读取失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func appendMessageToCurrentConversation(
        _ message: ChatMessage,
        conversationID: String
    ) {
        guard selectedConversationID == conversationID else { return }

        var currentMessages = messagesByPeer[conversationID] ?? []
        currentMessages.append(message)
        if currentMessages.count > Self.inMemoryMessageLimit {
            currentMessages.removeFirst(
                currentMessages.count - Self.inMemoryMessageLimit
            )
            hasMoreMessages = true
        }
        messagesByPeer[conversationID] = currentMessages
    }

    private func appendReceivedFiles(
        from message: ChatMessage,
        conversationID: String,
        senderName: String
    ) {
        guard message.direction == .incoming,
              !message.attachments.isEmpty else {
            return
        }

        let newFiles = message.attachments.map { attachment in
            ChatReceivedFile(
                id: message.id.uuidString + ":" + attachment.id,
                attachment: attachment,
                receivedAt: message.date,
                senderName: senderName
            )
        }
        var files = receivedFilesByConversation[conversationID] ?? []
        let existingIDs = Set(files.map(\.id))
        files.insert(contentsOf: newFiles.filter { !existingIDs.contains($0.id) }, at: 0)
        receivedFilesByConversation[conversationID] = Array(files.prefix(120))
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
                    self.groups = snapshot.groups
                    self.sortGroups()
                    self.repository.restoreGroups(self.groups)

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
                    if let selectedConversationID = self.selectedConversationID,
                       self.messages(for: selectedConversationID).isEmpty,
                       !self.isLoadingMessages {
                        self.loadRecentMessages(for: selectedConversationID)
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
        NSApp.isActive && selectedGroupID == nil && selectedPeerID == peer.id
    }

    private func sortPeers() {
        peers.sort {
            if $0.isOnline != $1.isOnline {
                return $0.isOnline && !$1.isOnline
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func sortGroups() {
        groups.sort {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func appendLog(_ message: String) {
        logs.append(message)
        if logs.count > 300 {
            logs.removeFirst(logs.count - 300)
        }
    }

    private func notificationPreview(for message: ChatMessage) -> String {
        let text = FeiQMessageFormatter.displayText(message.text)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        guard !message.attachments.isEmpty else { return "收到新消息" }
        let fileCount = message.attachments.filter { $0.kind == .file }.count
        let imageCount = message.attachments.count - fileCount
        if fileCount > 0 && imageCount > 0 {
            return "收到 \(imageCount) 张图片和 \(fileCount) 个文件"
        }
        if fileCount > 0 {
            return "收到 \(fileCount) 个文件"
        }
        return "收到 \(imageCount) 张图片"
    }

    func displayText(for message: ChatMessage) -> String {
        let formattedText = FeiQMessageFormatter.displayText(message.text)
        return FeiQInlineImageCodec.replacingMarkers(in: formattedText,
            with: message.attachments.isEmpty ? "[历史图片未保存，请对方重新发送]" : "")
    }

    private static var defaultHostName: String {
        if let localizedName = Host.current().localizedName,
           !localizedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return localizedName
        }
        return ProcessInfo.processInfo.hostName
    }
}
