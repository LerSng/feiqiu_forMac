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
    @Published private(set) var conversationSettingsByID: [String: ConversationSettings] = [:]
    @Published private(set) var savingConversationIDs: Set<String> = []
    @Published var editingConversationSettings: ConversationSettingsTarget?
    @Published var blockingConversation: ConversationSettingsTarget?
    @Published var conversationManagementError: String?
    @Published var selectedConversationTag: String?
    @Published var showsBlockedConversationsOnly = false
    @Published private(set) var isLoadingMessages = false
    @Published private(set) var hasMoreMessages = false
    @Published private(set) var hasLaterMessages = false
    @Published private(set) var isBrowsingHistory = false
    @Published private(set) var highlightedMessageID: UUID?
    @Published private(set) var messageNavigationID = UUID()
    @Published private(set) var isLocatingHistoryMessage = false
    @Published var historySearch: HistorySearchViewModel?
    @Published var historyArchive: HistoryArchiveViewModel?
    @Published var databaseMaintenance: DatabaseMaintenanceViewModel?
    @Published private(set) var isMaintainingDatabase = false
    @Published private(set) var requiresDatabaseRestart = false
    @Published var historyNavigationError: String?
    @Published private(set) var logs: [String] = []
    @Published private(set) var isRunning = false
    @Published private(set) var typingPeerIDs: Set<String> = []
    @Published private(set) var deletingMessageIDs: Set<UUID> = []
    @Published private(set) var fileTransferSnapshot = FileTransferSnapshot()
    @Published var showingFileTransfers = false
    let attachmentHistory: AttachmentHistoryViewModel
    @Published var imagePreview: ConversationImagePreviewModel?

    @Published var selectedPeerID: String?
    @Published var selectedGroupID: String?
    @Published var draft = ""
    @Published private(set) var draftAttachments: [ChatAttachment] = []
    @Published private(set) var pendingImageCount = 0
    @Published var imageSelectionError: String?
    @Published private(set) var isPreparingAttachment = false
    @Published private(set) var isCapturingScreenshot = false
    @Published private(set) var isPreparingDrop = false
    @Published private(set) var dropPreparedCount = 0
    @Published private(set) var dropItemCount = 0
    @Published var dropSendError: String?
    @Published var searchText = ""
    @Published var nickname: String
    @Published var hostName: String
    @Published var groupName: String
    @Published var chatLoadAnimationMode: ChatLoadAnimationMode
    @Published var messageNotificationSound: MessageNotificationSound
    @Published var settingsError: String?
    @Published var showingSettings = false
    @Published private(set) var windowShakeID = UUID()
    @Published private(set) var shakeCoolingDown = false
    @Published var remoteAssistanceRequest: FeiQRemoteAssistanceRequest?

    @Published var showingLogs = false
    @Published var imageDeletionError: String?
    @Published var messageDeletionError: String?
    @Published var showingGroupEditor = false
    @Published var editingGroupID: String?

    private let repository: ChatRepository
    private let settingsRepository: AppSettingsRepository
    private let notificationSoundService: NotificationSoundService
    private var soundPreview: NSSound?
    private var offlineTimer: Timer?
    private var historyRequestGeneration = 0
    private var historyNavigationGeneration = 0
    private var receivedMessageDuringHistoryLoad = false
    private var historyMessageUpdates: [UUID: ChatMessage] = [:]
    private var deletedImageIDsByMessage: [UUID: Set<String>] = [:]
    private var deletingImageKeys = Set<String>()
    private var imagePreparationGeneration = UUID()
    private var dropRequestID: UUID?
    private var dropCancellation: DroppedAttachmentCancellation?
    private var pendingDropRequests: Set<UUID> = []
    private var pendingAttachmentOperations = 0
    private var isRefreshingHistory = false
    private var hasLoadedHistory = false
    private var isLoadingHistory = false
    private var wantsToBeOnline = true
    private var typingTimers: [String: DispatchWorkItem] = [:]
    private var localTypingPeerID: String?
    private var localTypingStopWorkItem: DispatchWorkItem?

    private static let messagePageSize = 60
    private static let inMemoryMessageLimit = 240

    var isPreparingPastedImage: Bool { pendingImageCount > 0 }
    var draftImageCount: Int { draftAttachments.filter(\.isImage).count }
    var maximumAlbumImageCount: Int { ChatAttachmentGroup.maximumImageCount }
    var isDatabaseUnavailable: Bool { isMaintainingDatabase || requiresDatabaseRestart }

    func attachmentGroups(for message: ChatMessage) -> [ChatAttachmentGroup] {
        ChatAttachmentGroup.makeGroups(from: message.attachments)
    }

    var canSendShake: Bool {
        !isDatabaseUnavailable && isRunning && selectedPeer?.isOnline == true && !shakeCoolingDown && !isSelectedConversationBlocked
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
        return peers.filter { peer in
            matchesConversationFilters(peer.id) && (query.isEmpty
                || peer.displayName.localizedCaseInsensitiveContains(query)
                || displayName(for: peer).localizedCaseInsensitiveContains(query)
                || peer.hostName.localizedCaseInsensitiveContains(query)
                || peer.ipAddress.localizedCaseInsensitiveContains(query)
                || peer.group.localizedCaseInsensitiveContains(query)
                || conversationSettings(for: peer.id).tags.contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    var filteredGroups: [ChatGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.filter { group in
            matchesConversationFilters(group.id) && (query.isEmpty
                || group.displayName.localizedCaseInsensitiveContains(query)
                || displayName(for: group).localizedCaseInsensitiveContains(query)
                || group.ownerName.localizedCaseInsensitiveContains(query)
                || conversationSettings(for: group.id).tags.contains { $0.localizedCaseInsensitiveContains(query) }
                || group.memberIDs.contains { memberID in
                    peers.first(where: { $0.id == memberID }).map {
                        displayName(for: $0).localizedCaseInsensitiveContains(query)
                            || $0.displayName.localizedCaseInsensitiveContains(query)
                    } == true
                })
        }
    }

    init(
        repository: ChatRepository,
        settingsRepository: AppSettingsRepository,
        notificationSoundService: NotificationSoundService = NotificationSoundService()
    ) {
        self.repository = repository
        self.settingsRepository = settingsRepository
        self.notificationSoundService = notificationSoundService
        attachmentHistory = AttachmentHistoryViewModel(search: repository.searchAttachments)
        conversationSettingsByID = repository.conversationSettingsSnapshot
        conversationManagementError = repository.conversationSettingsLoadError.map { "会话设置读取失败：\($0)" }

        let settings = settingsRepository.load()
        nickname = settings.identity.nickname
        hostName = settings.identity.hostName
        groupName = settings.identity.groupName
        chatLoadAnimationMode = settings.chatLoadAnimationMode
        messageNotificationSound = settings.messageNotificationSound

        repository.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event)
            }
        }

        loadHistory()
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
        dropCancellation?.cancel()
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

    func conversationSettings(for conversationID: String) -> ConversationSettings {
        repository.conversationSettings(for: conversationID)
    }

    var isSelectedConversationBlocked: Bool {
        selectedConversationID.map { conversationSettings(for: $0).isBlocked } ?? false
    }

    func displayName(for peer: FeiQPeer) -> String {
        let remark = conversationSettings(for: peer.id).remark
        return remark.isEmpty ? peer.displayName : remark
    }

    func displayName(for group: ChatGroup) -> String {
        let remark = conversationSettings(for: group.id).remark
        return remark.isEmpty ? group.displayName : remark
    }

    var conversationTags: [String] {
        let identifiers = Set(peers.map(\.id) + groups.map(\.id))
        let tags = conversationSettingsByID.filter { identifiers.contains($0.key) }.values.flatMap(\.tags)
        var seen = Set<String>()
        return tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private func matchesConversationFilters(_ identifier: String) -> Bool {
        let settings = conversationSettings(for: identifier)
        if showsBlockedConversationsOnly && !settings.isBlocked { return false }
        if let selectedConversationTag {
            return settings.tags.contains { $0.caseInsensitiveCompare(selectedConversationTag) == .orderedSame }
        }
        return true
    }

    private func settingsTarget(for identifier: String) -> ConversationSettingsTarget? {
        if let peer = peers.first(where: { $0.id == identifier }) {
            return ConversationSettingsTarget(id: identifier, originalName: peer.displayName, isGroup: false)
        }
        if let group = groups.first(where: { $0.id == identifier }) {
            return ConversationSettingsTarget(id: identifier, originalName: group.displayName, isGroup: true)
        }
        return nil
    }

    func editConversationSettings(_ identifier: String) {
        editingConversationSettings = settingsTarget(for: identifier)
    }

    func toggleConversationPin(_ identifier: String) {
        updateConversationSettings(identifier) { $0.isPinned.toggle() }
    }

    func toggleConversationMute(_ identifier: String) {
        updateConversationSettings(identifier) { $0.isMuted.toggle() }
    }

    func requestConversationBlock(_ identifier: String) {
        if conversationSettings(for: identifier).isBlocked {
            setConversationBlocked(false, for: identifier)
        } else {
            blockingConversation = settingsTarget(for: identifier)
        }
    }

    func setConversationBlocked(_ blocked: Bool, for identifier: String) {
        updateConversationSettings(identifier) { $0.isBlocked = blocked }
    }

    func saveConversationDetails(_ identifier: String, remark: String, tags: String,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        updateConversationSettings(identifier, changes: {
            $0.remark = remark
            $0.tags = ConversationSettings.parseTags(tags)
        }, completion: completion)
    }

    private func updateConversationSettings(
        _ identifier: String, changes: (inout ConversationSettings) -> Void,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        guard !isDatabaseUnavailable, settingsTarget(for: identifier) != nil, !savingConversationIDs.contains(identifier) else {
            completion?(.failure(ConversationSettingsError.unavailable))
            return
        }
        var settings = conversationSettings(for: identifier)
        changes(&settings)
        savingConversationIDs.insert(identifier)
        repository.saveConversationSettings(settings, for: identifier) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.savingConversationIDs.remove(identifier)
                switch result {
                case .success(let saved):
                    self.conversationSettingsByID[identifier] = saved.isDefault ? nil : saved
                    self.sortPeers()
                    self.sortGroups()
                    if let tag = self.selectedConversationTag,
                       !self.conversationTags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                        self.selectedConversationTag = nil
                    }
                    if saved.isBlocked {
                        self.markMessagesRead(for: identifier)
                        self.typingTimers[identifier]?.cancel()
                        self.typingTimers.removeValue(forKey: identifier)
                        self.typingPeerIDs.remove(identifier)
                        if self.selectedConversationID == identifier {
                            self.cancelDroppedAttachments()
                            self.stopLocalTyping()
                        }
                    }
                    if saved.suppressesAlerts, self.remoteAssistanceRequest?.peer.id == identifier {
                        self.remoteAssistanceRequest = nil
                    }
                    completion?(.success(()))
                case .failure(let error):
                    if let completion { completion(.failure(error)) }
                    else { self.conversationManagementError = "会话设置保存失败：\(error.localizedDescription)" }
                }
            }
        }
    }

    func isPeerTyping(_ peerID: String) -> Bool {
        typingPeerIDs.contains(peerID)
    }

    /// Starts or refreshes the local typing notification for the selected
    /// peer. The stop packet is debounced so Windows FeiQ does not receive a
    /// start/stop pair for every keystroke.
    func draftDidChange() {
        guard let peer = selectedPeer, !isSelectedConversationBlocked else {
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
        guard !isDatabaseUnavailable, unreadCount(for: conversationID) > 0 else { return }
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
        guard !isDatabaseUnavailable else { return }
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
        guard !isDatabaseUnavailable else { return }
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

    func makeHistoryArchiveModel(
        mode: ChatHistoryArchiveMode = .export, query: ChatHistorySearchQuery = .init()
    ) -> HistoryArchiveViewModel {
        HistoryArchiveViewModel(mode: mode, query: query, repository: repository) { [weak self] in
            self?.refreshImportedHistory()
        }
    }

    func openHistoryArchive(mode: ChatHistoryArchiveMode) {
        guard !isDatabaseUnavailable else { return }
        historyArchive = makeHistoryArchiveModel(mode: mode, query: .init(conversationID: selectedConversationID))
    }

    func openDatabaseMaintenance() {
        guard !isDatabaseUnavailable, databaseMaintenance == nil else { return }
        databaseMaintenance = DatabaseMaintenanceViewModel(service: repository.databaseMaintenanceService,
            authorize: { [weak self] restoring, completion in
                guard let self else { completion(.failure(DatabaseMaintenanceError.busy)); return }
                self.authorizeDatabaseMaintenance(restoring: restoring, completion: completion)
            }, finish: { [weak self] attachmentsChanged, requiresRestart in
                self?.finishDatabaseMaintenance(attachmentsChanged: attachmentsChanged, requiresRestart: requiresRestart)
            })
    }

    private func maintenanceAvailabilityError(restoring: Bool) -> Error? {
        if requiresDatabaseRestart { return DatabaseMaintenanceError.restartRequired }
        if isRunning || wantsToBeOnline || !hasLoadedHistory || isLoadingHistory || isRefreshingHistory
            || isPreparingDrop || !pendingDropRequests.isEmpty || pendingAttachmentOperations > 0
            || isPreparingPastedImage || isPreparingAttachment || isCapturingScreenshot
            || !deletingImageKeys.isEmpty || !deletingMessageIDs.isEmpty || !savingConversationIDs.isEmpty
            || historyArchive?.isBusy == true || fileTransferSnapshot.unfinishedCount > 0 {
            return DatabaseMaintenanceError.busy
        }
        if restoring && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty) {
            return DatabaseMaintenanceError.unsentDraft
        }
        return nil
    }

    private func authorizeDatabaseMaintenance(restoring: Bool, completion: @escaping (Result<Set<String>, Error>) -> Void) {
        guard !isDatabaseUnavailable else { completion(.failure(DatabaseMaintenanceError.busy)); return }
        if let error = maintenanceAvailabilityError(restoring: restoring) { completion(.failure(error)); return }
        isMaintainingDatabase = true
        repository.beginDatabaseMaintenance { [self] result in
            DispatchQueue.main.async { [self] in
                switch result {
                case .failure(let error):
                    isMaintainingDatabase = false
                    completion(.failure(error))
                case .success(let protected):
                    if let error = maintenanceAvailabilityError(restoring: restoring) {
                        repository.endDatabaseMaintenance(requiresRestart: false)
                        isMaintainingDatabase = false
                        completion(.failure(error))
                        return
                    }
                    completion(.success(protected.union(draftAttachments.map(\.localPath))))
                }
            }
        }
    }

    private func finishDatabaseMaintenance(attachmentsChanged: Bool, requiresRestart: Bool) {
        repository.endDatabaseMaintenance(requiresRestart: requiresRestart)
        requiresDatabaseRestart = requiresRestart
        isMaintainingDatabase = false
        if requiresRestart {
            wantsToBeOnline = false
            isRunning = false
            historySearch?.cancel()
            attachmentHistory.stop()
            cancelHistoryNavigation()
            imagePreview = nil
        } else if attachmentsChanged {
            imagePreview = nil
            receivedFilesByConversation.removeAll()
            returnToLatestMessages()
            if let conversationID = selectedConversationID { loadReceivedFiles(for: conversationID) }
            attachmentHistory.refresh()
        }
    }

    func refreshImportedHistory() {
        guard !requiresDatabaseRestart else { return }
        isRefreshingHistory = true
        repository.loadSnapshot { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshingHistory = false
                guard !self.requiresDatabaseRestart else { return }
                switch result {
                case .success(let snapshot):
                    self.mergeRestoredPeers(snapshot.peers.map { peer in
                        var restored = peer
                        restored.isOnline = false
                        return restored
                    })
                    self.repository.restorePeers(self.peers)
                    self.groups = snapshot.groups
                    self.sortGroups()
                    self.repository.restoreGroups(self.groups)
                    for (identifier, count) in snapshot.unreadCountsByPeer where self.unreadCountsByPeer[identifier] == nil {
                        self.unreadCountsByPeer[identifier] = count
                    }
                    if let conversationID = self.selectedConversationID {
                        self.returnToLatestMessages()
                        self.loadReceivedFiles(for: conversationID)
                    }
                    self.appendLog("已刷新导入后的联系人、群聊和历史消息")
                case .failure(let error): self.appendLog("导入完成，但刷新历史记录失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func openHistorySearch(for conversationID: String? = nil) {
        guard !isDatabaseUnavailable else { return }
        cancelHistoryNavigation()
        historyNavigationError = nil
        historySearch = HistorySearchViewModel(conversationID: conversationID, search: repository.searchMessages)
    }

    func cancelHistoryNavigation() {
        historyNavigationGeneration += 1
        isLocatingHistoryMessage = false
    }

    func revealHistoryMessage(_ result: ChatHistorySearchResult) {
        revealHistoryMessage(
            conversationID: result.conversationID, messageID: result.id, isGroup: result.isGroup,
            closingDownloadCenter: false
        )
    }

    func revealHistoryAttachment(_ result: ChatAttachmentHistoryResult) {
        revealHistoryMessage(
            conversationID: result.conversationID, messageID: result.messageID, isGroup: result.isGroup,
            closingDownloadCenter: true
        )
    }

    private func revealHistoryMessage(
        conversationID: String, messageID: UUID, isGroup: Bool, closingDownloadCenter: Bool
    ) {
        guard !isLocatingHistoryMessage else { return }
        historyNavigationError = nil
        isLocatingHistoryMessage = true
        historyNavigationGeneration += 1
        let requestGeneration = historyNavigationGeneration
        repository.loadMessageContext(
            for: conversationID, messageID: messageID, limit: Self.messagePageSize
        ) { [weak self] response in
            DispatchQueue.main.async {
                guard let self, self.historyNavigationGeneration == requestGeneration else { return }
                self.isLocatingHistoryMessage = false
                switch response {
                case .success(let context):
                    let exists = isGroup
                        ? self.groups.contains { $0.id == conversationID }
                        : self.peers.contains { $0.id == conversationID }
                    guard exists else {
                        self.historyNavigationError = ChatHistorySearchError.messageUnavailable.localizedDescription
                        return
                    }
                    let currentMessages = self.messagesByPeer[conversationID] ?? []
                    let updates = Dictionary(uniqueKeysWithValues: currentMessages.map { ($0.id, $0) })
                    self.activateConversation(
                        peerID: isGroup ? nil : conversationID,
                        groupID: isGroup ? conversationID : nil,
                        markRead: true, loadMessages: false
                    )
                    self.historyRequestGeneration += 1
                    self.historyMessageUpdates.removeAll()
                    self.messagesByPeer[conversationID] = context.messages.map {
                        (updates[$0.id] ?? $0).removingImages(withIDs: self.deletedImageIDsByMessage[$0.id] ?? [])
                    }
                    self.hasMoreMessages = context.hasEarlier
                    self.hasLaterMessages = context.hasLater
                    self.isLoadingMessages = false
                    self.isBrowsingHistory = true
                    self.highlightedMessageID = messageID
                    self.messageNavigationID = UUID()
                    self.historySearch = nil
                    if closingDownloadCenter { self.showingFileTransfers = false }
                case .failure(let error):
                    self.historyNavigationError = error.localizedDescription
                }
            }
        }
    }

    func returnToLatestMessages() {
        guard let conversationID = selectedConversationID else { return }
        historyRequestGeneration += 1
        messagesByPeer[conversationID] = []
        hasMoreMessages = false
        hasLaterMessages = false
        isBrowsingHistory = false
        highlightedMessageID = nil
        markMessagesRead(for: conversationID)
        loadRecentMessages(for: conversationID)
        messageNavigationID = UUID()
    }

    func loadLaterMessages(
        for conversationID: String,
        after message: ChatMessage,
        completion: (() -> Void)? = nil
    ) {
        guard selectedConversationID == conversationID, hasLaterMessages, !isLoadingMessages else { return }
        historyMessageUpdates.removeAll()
        receivedMessageDuringHistoryLoad = false
        isLoadingMessages = true
        let requestGeneration = historyRequestGeneration
        repository.loadLaterMessages(for: conversationID, after: message, limit: Self.messagePageSize) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.selectedConversationID == conversationID,
                      self.historyRequestGeneration == requestGeneration else { return }
                switch result {
                case .success(let page):
                    self.messagesByPeer[conversationID] = self.mergeMessages(
                        page.messages.map { self.historyMessageUpdates[$0.id] ?? $0 },
                        with: self.messagesByPeer[conversationID] ?? []
                    )
                    self.hasLaterMessages = page.hasMore || self.receivedMessageDuringHistoryLoad
                    completion?()
                case .failure(let error):
                    self.appendLog("后续聊天记录读取失败：\(error.localizedDescription)")
                }
                self.isLoadingMessages = false
            }
        }
    }

    func startNetwork() {
        guard !isDatabaseUnavailable else { return }
        wantsToBeOnline = true
        guard hasLoadedHistory else {
            if !isLoadingHistory { loadHistory() }
            return
        }
        repository.start(identity: currentIdentity)
    }

    func stopNetwork() {
        guard !isDatabaseUnavailable else { return }
        wantsToBeOnline = false
        repository.stop()
    }

    func setOnlineStatus(_ isOnline: Bool) {
        guard !isDatabaseUnavailable else { return }
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
        guard !isDatabaseUnavailable else { return }
        repository.refreshDiscovery()
        appendLog("手动发送局域网发现广播")
    }

    @discardableResult
    func saveSettings() -> Bool {
        guard !isDatabaseUnavailable else { return false }
        settingsError = nil
        do { try notificationSoundService.prepare(messageNotificationSound) }
        catch { settingsError = "提示音保存失败：" + error.localizedDescription; return false }
        nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        hostName = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        groupName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        if nickname.isEmpty { nickname = "飞秋 Mac" }
        if hostName.isEmpty { hostName = Self.defaultHostName }

        settingsRepository.save(
            AppSettings(
                identity: currentIdentity,
                chatLoadAnimationMode: chatLoadAnimationMode,
                messageNotificationSound: messageNotificationSound
            )
        )
        repository.updateIdentity(currentIdentity)
        repository.announce()
        appendLog("已保存本机资料，并刷新上线信息")
        return true
    }

    func previewNotificationSound() {
        stopNotificationSoundPreview()
        settingsError = nil
        if messageNotificationSound == .none { return }
        if messageNotificationSound == .system { NSSound.beep(); return }
        guard let url = notificationSoundService.sourceURL(for: messageNotificationSound),
              let sound = NSSound(contentsOf: url, byReference: false), sound.play() else {
            settingsError = NotificationSoundError.previewFailed.localizedDescription
            return
        }
        soundPreview = sound
    }

    func stopNotificationSoundPreview() {
        soundPreview?.stop()
        soundPreview = nil
    }

    func reloadNotificationSoundSetting() {
        messageNotificationSound = settingsRepository.load().messageNotificationSound
    }

    var attachmentDropUnavailableReason: String? {
        if isDatabaseUnavailable { return "数据库正在维护，请稍后再发送" }
        if isPreparingDrop { return "正在准备上一批附件，请稍候或取消后重试" }
        if selectedConversationID == nil { return "请先选择联系人或群聊" }
        if isSelectedConversationBlocked { return ConversationSettingsError.blocked.localizedDescription }
        if !isRunning { return "局域网服务未启动，暂时无法发送" }
        if let peer = selectedPeer {
            return peer.isOnline && !peer.ipAddress.isEmpty ? nil : "联系人已离线，暂时无法发送"
        }
        if let group = selectedGroup {
            return members(for: group.id).contains { $0.isOnline && !$0.ipAddress.isEmpty && !conversationSettings(for: $0.id).isBlocked }
                ? nil : "群聊没有在线成员，暂时无法发送"
        }
        return "当前会话不可用"
    }

    @discardableResult
    func sendDroppedAttachments(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty, providers.contains(where: ChatAttachmentDrop.supports) else { return false }
        if let reason = attachmentDropUnavailableReason {
            dropSendError = reason
            return false
        }
        guard providers.count <= DroppedAttachmentService.maximumItemCount else {
            dropSendError = DroppedAttachmentError.tooManyItems.localizedDescription
            return false
        }
        let destination: DroppedMessageDestination
        if let peer = selectedPeer {
            destination = .peer(peer)
        } else if let group = selectedGroup {
            destination = .group(group, members(for: group.id).filter { $0.isOnline && !$0.ipAddress.isEmpty && !conversationSettings(for: $0.id).isBlocked })
        } else {
            return false
        }
        let requestID = UUID()
        pendingDropRequests.insert(requestID)
        dropRequestID = requestID
        dropSendError = nil
        isPreparingDrop = true
        dropPreparedCount = 0
        dropItemCount = providers.count
        dropCancellation = repository.prepareDroppedAttachments(providers) { [weak self] completed, total in
            DispatchQueue.main.async {
                guard let self, self.dropRequestID == requestID else { return }
                self.dropPreparedCount = completed
                self.dropItemCount = total
            }
        } completion: { [weak self, repository] result in
            DispatchQueue.main.async {
                self?.pendingDropRequests.remove(requestID)
                guard let self, self.dropRequestID == requestID else {
                    if case .success(let prepared) = result {
                        repository.discardPreparedAttachments(prepared.attachments) { _ in }
                    }
                    return
                }
                self.dropRequestID = nil
                self.dropCancellation = nil
                self.isPreparingDrop = false
                switch result {
                case .success(let prepared):
                    guard let destination = self.validatedDropDestination(destination) else {
                        repository.discardPreparedAttachments(prepared.attachments) { _ in }
                        self.dropSendError = "会话或在线状态已变化，本批附件未发送，请重新拖入。"
                        return
                    }
                    for batch in ChatAttachmentGroup.makeGroups(from: prepared.attachments) {
                        self.sendDroppedBatch(batch.attachments, to: destination)
                    }
                    if !prepared.failures.isEmpty {
                        let details = prepared.failures.prefix(8).joined(separator: "\n")
                        let remainder = prepared.failures.count > 8 ? "\n另有 \(prepared.failures.count - 8) 项失败，详见网络日志。" : ""
                        self.dropSendError = "已提交发送 \(prepared.attachments.count) 个附件，\(prepared.failures.count) 项未发送：\n\(details)\(remainder)"
                        for failure in prepared.failures { self.appendLog("拖拽附件准备失败：\(failure)") }
                    }
                case .failure(let error):
                    self.dropSendError = error.localizedDescription
                }
            }
        }
        return true
    }

    func cancelDroppedAttachments() {
        dropRequestID = nil
        dropCancellation?.cancel()
        dropCancellation = nil
        isPreparingDrop = false
        dropPreparedCount = 0
        dropItemCount = 0
    }

    private enum DroppedMessageDestination {
        case peer(FeiQPeer)
        case group(ChatGroup, [FeiQPeer])
    }

    private func validatedDropDestination(_ destination: DroppedMessageDestination) -> DroppedMessageDestination? {
        guard isRunning, !isSelectedConversationBlocked else { return nil }
        switch destination {
        case .peer(let original):
            guard let peer = selectedPeer, peer.id == original.id, peer.isOnline else { return nil }
            return .peer(peer)
        case .group(let original, let originalMembers):
            guard let group = selectedGroup, group.id == original.id, Set(group.memberIDs) == Set(original.memberIDs) else { return nil }
            let currentMembers = members(for: group.id).filter { peer in
                peer.isOnline && !conversationSettings(for: peer.id).isBlocked
                    && originalMembers.contains { $0.id == peer.id }
            }
            return currentMembers.isEmpty ? nil : .group(group, currentMembers)
        }
    }

    private func sendDroppedBatch(_ attachments: [ChatAttachment], to destination: DroppedMessageDestination) {
        switch destination {
        case .peer(let peer):
            let message = ChatMessage(direction: .outgoing, text: "", senderName: nickname,
                                      recipientName: peer.displayName, attachments: attachments)
            appendMessageToCurrentConversation(message, conversationID: peer.id)
            repository.sendMessage(message, to: peer, unreadCount: unreadCount(for: peer.id))
        case .group(let group, let members):
            let message = ChatMessage(direction: .outgoing, text: "", senderName: nickname,
                                      recipientName: group.displayName, attachments: attachments)
            appendMessageToCurrentConversation(message, conversationID: group.id)
            repository.sendGroupMessage(message, to: group, members: members)
        }
    }

    func sendDraft() {
        guard !isDatabaseUnavailable, !isSelectedConversationBlocked else { return }
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
        guard !isDatabaseUnavailable, selectedConversationID != nil, count > 0 else { return false }
        let available = maximumAlbumImageCount - draftImageCount - pendingImageCount
        guard count <= available else {
            imageSelectionError = "每条消息最多合并 \(maximumAlbumImageCount) 张照片，当前还可添加 \(max(0, available)) 张。"
            return false
        }
        imageSelectionError = nil
        pendingImageCount += count
        pendingAttachmentOperations += count
        return true
    }

    private func finishPreparingImage(_ result: Result<ChatAttachment, Error>, generation: UUID) {
        pendingAttachmentOperations = max(0, pendingAttachmentOperations - 1)
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
        guard !isDatabaseUnavailable, selectedConversationID != nil, !isCapturingScreenshot else { return }

        isCapturingScreenshot = true
        pendingAttachmentOperations += 1
        repository.captureScreenshot { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCapturingScreenshot = false
                self.pendingAttachmentOperations = max(0, self.pendingAttachmentOperations - 1)

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
        guard !isDatabaseUnavailable else { return }
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

    func previewImage(_ attachment: ChatAttachment, from message: ChatMessage, conversationID: String) {
        guard selectedConversationID == conversationID, attachment.isImage else { return }
        imagePreview = ConversationImagePreviewModel(
            conversationID: conversationID,
            conversationTitle: selectedGroup?.displayName ?? selectedPeer?.displayName ?? "",
            message: message, attachmentID: attachment.id,
            loadedMessages: messages(for: conversationID)
        ) { [repository] completion in
            repository.loadConversationImages(for: conversationID, completion: completion)
        }
    }

    private func updateImagePreview(_ message: ChatMessage, conversationID: String) {
        guard imagePreview?.conversationID == conversationID else { return }
        imagePreview?.update(message)
    }

    func deleteImage(_ attachmentID: String, from message: ChatMessage, conversationID: String) {
        guard !isDatabaseUnavailable else { return }
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
                    self.updateImagePreview(updated, conversationID: conversationID)
                case .failure(let error):
                    self.deletedImageIDsByMessage[message.id]?.remove(attachmentID)
                    self.imageDeletionError = error.localizedDescription
                    self.appendLog("删除图片失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func deleteMessage(_ message: ChatMessage, conversationID: String) {
        guard !isDatabaseUnavailable else { return }
        guard deletingMessageIDs.insert(message.id).inserted else { return }
        let currentMessages = messagesByPeer[conversationID] ?? []
        guard currentMessages.contains(where: { $0.id == message.id }) else {
            deletingMessageIDs.remove(message.id)
            return
        }

        historyMessageUpdates.removeValue(forKey: message.id)
        messagesByPeer[conversationID]?.removeAll { $0.id == message.id }
        receivedFilesByConversation[conversationID]?.removeAll {
            $0.id.hasPrefix(message.id.uuidString + ":")
        }

        repository.deleteMessage(message, conversationID: conversationID) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.deletingMessageIDs.remove(message.id)
                if case .failure(let error) = result {
                    let liveMessages = self.messagesByPeer[conversationID] ?? []
                    self.messagesByPeer[conversationID] = self.mergeMessages(
                        [message],
                        with: liveMessages
                    )
                    self.messageDeletionError = "消息删除失败：\(error.localizedDescription)"
                    self.appendLog("删除消息失败：\(error.localizedDescription)")
                } else if self.imagePreview?.conversationID == conversationID {
                    self.imagePreview?.removeMessage(message.id)
                }
            }
        }
    }

    func chooseAndAddImages() {
        guard !isDatabaseUnavailable, selectedConversationID != nil else { return }
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
        guard !isDatabaseUnavailable, selectedConversationID != nil else { return }

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

        pendingAttachmentOperations += 1
        repository.prepareOutgoingFile(from: urls[index]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingAttachmentOperations = max(0, self.pendingAttachmentOperations - 1)

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

    func setFileTransferQueuePaused(_ paused: Bool) {
        guard !isDatabaseUnavailable else { return }
        repository.fileTransferCenter.setPaused(paused)
    }

    func setFileTransferConcurrency(_ count: Int) {
        guard !isDatabaseUnavailable else { return }
        repository.fileTransferCenter.setMaximumConcurrentTransfers(count)
    }

    func cancelFileTransfer(_ identifier: UUID) {
        repository.fileTransferCenter.cancel(identifier)
    }

    func retryFileTransfer(_ identifier: UUID) {
        guard !isDatabaseUnavailable else { return }
        repository.fileTransferCenter.retry(identifier)
    }

    func prioritizeFileTransfer(_ identifier: UUID) {
        repository.fileTransferCenter.moveToFront(identifier)
    }

    func moveFileTransfer(_ identifier: UUID, by offset: Int) {
        repository.fileTransferCenter.move(identifier, by: offset)
    }

    func removeFileTransfer(_ identifier: UUID) {
        repository.fileTransferCenter.remove(identifier)
    }

    func cancelAllFileTransfers(direction: FileTransferDirection? = nil) {
        repository.fileTransferCenter.cancelAll(direction: direction)
    }

    func retryFailedFileTransfers(direction: FileTransferDirection? = nil) {
        guard !isDatabaseUnavailable else { return }
        repository.fileTransferCenter.retryFailed(direction: direction)
    }

    func clearFinishedFileTransfers(direction: FileTransferDirection? = nil) {
        repository.fileTransferCenter.clearFinished(direction: direction)
    }

    private var currentIdentity: FeiQIdentity {
        FeiQIdentity(
            nickname: nickname,
            hostName: hostName,
            groupName: groupName
        )
    }

    private func receiveDirectMessage(_ message: ChatMessage, from peer: FeiQPeer, isShake: Bool = false) {
        guard !conversationSettings(for: peer.id).isBlocked else { return }
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
            group.memberIDs.contains(peer.id) && !conversationSettings(for: group.id).isBlocked
        }
        if !isViewing, isShake || !belongsToGroup {
            repository.notifyIncomingMessage(
                text: notificationPreview(for: message),
                from: displayName(for: peer),
                conversationID: peer.id
            )
        }
    }

    private func handle(_ event: ChatRepositoryEvent) {
        guard !requiresDatabaseRestart else { return }
        switch event {
        case .fileTransfersChanged(let snapshot):
            fileTransferSnapshot = snapshot

        case .historyAttachmentsChanged:
            attachmentHistory.refresh()

        case .peerShook(let peer):
            guard !conversationSettings(for: peer.id).isBlocked else { return }
            mergePeer(peer)
            let message = ChatMessage(
                direction: .incoming, text: "对方向你发送了抖一抖",
                senderName: peer.displayName, recipientName: nickname
            )
            receiveDirectMessage(message, from: peer, isShake: true)
            if !conversationSettings(for: peer.id).isMuted { windowShakeID = UUID() }

        case .remoteAssistanceRequested(let request):
            guard !conversationSettings(for: request.peer.id).suppressesAlerts else { return }
            mergePeer(request.peer)
            remoteAssistanceRequest = request
            appendLog(
                "收到 \(request.peer.displayName) 的远程协助请求（0xB0），已等待用户确认"
            )

        case .peerUpdated(let peer):
            mergePeer(peer)
            if selectedConversationID == nil, peer.isOnline, !conversationSettings(for: peer.id).isBlocked {
                selectPeer(peer.id)
            }

        case .peerTyping(let peer, let isTyping):
            guard !conversationSettings(for: peer.id).isBlocked else { return }
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
            guard !conversationSettings(for: peer.id).isBlocked else { return }
            let message = message.removingImages(withIDs: deletedImageIDsByMessage[message.id] ?? [])
            updateImagePreview(message, conversationID: peer.id)
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
            guard !conversationSettings(for: group.id).isBlocked else { return }
            if !groups.contains(where: { $0.id == group.id }) {
                groups.append(group)
                sortGroups()
            }

            let isViewing = NSApp.isActive && selectedGroupID == group.id && !isBrowsingHistory
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
                    from: displayName(for: group) + " · " + sender,
                    conversationID: group.id
                )
            }

        case .groupMessageUpdated(let message, let group):
            guard !conversationSettings(for: group.id).isBlocked else { return }
            let message = message.removingImages(withIDs: deletedImageIDsByMessage[message.id] ?? [])
            updateImagePreview(message, conversationID: group.id)
            if let index = messagesByPeer[group.id]?.firstIndex(where: { $0.id == message.id }) {
                messagesByPeer[group.id]?[index] = message
            }
            if isLoadingMessages, selectedConversationID == group.id {
                historyMessageUpdates[message.id] = message
            }
            appendReceivedFiles(from: message, conversationID: group.id, senderName: message.senderName)
            repository.persistGroupMessage(message, for: group, unreadCount: unreadCount(for: group.id))

        case .networkStateChanged(let running):
            isRunning = running
            if !running { cancelDroppedAttachments() }

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
        markRead: Bool,
        loadMessages: Bool = true
    ) {
        guard !isDatabaseUnavailable else { return }
        if selectedPeerID == peerID, selectedGroupID == groupID {
            if markRead, let conversationID = groupID ?? peerID {
                markMessagesRead(for: conversationID)
            }
            return
        }

        cancelDroppedAttachments()
        selectedPeerID = peerID
        selectedGroupID = groupID
        imagePreview = nil
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
        hasLaterMessages = false
        isBrowsingHistory = false
        highlightedMessageID = nil

        guard let conversationID = groupID ?? peerID else { return }
        receivedFilesByConversation[conversationID] = []

        if markRead {
            markMessagesRead(for: conversationID)
        }
        if loadMessages { loadRecentMessages(for: conversationID) }
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
        updateImagePreview(message, conversationID: conversationID)
        guard selectedConversationID == conversationID else { return }

        if isBrowsingHistory {
            if message.direction == .outgoing {
                returnToLatestMessages()
            } else {
                hasLaterMessages = true
                receivedMessageDuringHistoryLoad = true
                return
            }
        }

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
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        repository.loadSnapshot { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingHistory = false

                switch result {
                case .success(let snapshot):
                    self.hasLoadedHistory = true
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
                    self.unreadCountsByPeer = unreadCounts.filter { !self.conversationSettings(for: $0.key).isBlocked }
                    self.appendLog(
                        "已加载 \(snapshot.totalMessageCount) 条聊天记录，采用 SQLite 分页存储：\(self.repository.historyLocationDescription)"
                    )
                    if let selectedConversationID = self.selectedConversationID,
                       self.messages(for: selectedConversationID).isEmpty,
                       !self.isLoadingMessages {
                        self.loadRecentMessages(for: selectedConversationID)
                    }
                    if self.wantsToBeOnline { self.startNetwork() }

                case .failure(let error):
                    self.appendLog("聊天记录数据库读取失败：\(error.localizedDescription)")
                    self.conversationManagementError = "无法恢复会话资料，未启动网络以避免屏蔽失效：\(error.localizedDescription)"
                }
            }
        }
    }

    private func mergePeer(_ peer: FeiQPeer) {
        if let index = peers.firstIndex(where: { $0.id == peer.id }) {
            guard peers[index].lastSeen <= peer.lastSeen else { return }
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
                mergedPeers[livePeer.id] = livePeer.isOnline || livePeer.lastSeen >= storedPeer.lastSeen ? livePeer : storedPeer
            } else {
                mergedPeers[livePeer.id] = livePeer
            }
        }
        peers = Array(mergedPeers.values)
        sortPeers()
    }

    private func markOfflinePeers() {
        guard !isDatabaseUnavailable else { return }
        repository.markOfflinePeers(
            before: Date().addingTimeInterval(-75)
        )
    }

    private func isViewingConversation(for peer: FeiQPeer) -> Bool {
        NSApp.isActive && selectedGroupID == nil && selectedPeerID == peer.id && !isBrowsingHistory
    }

    private func sortPeers() {
        peers.sort { first, second in
            let firstPinned = conversationSettings(for: first.id).isPinned
            let secondPinned = conversationSettings(for: second.id).isPinned
            if firstPinned != secondPinned { return firstPinned }
            if first.isOnline != second.isOnline {
                return first.isOnline && !second.isOnline
            }
            let comparison = displayName(for: first).localizedStandardCompare(displayName(for: second))
            return comparison == .orderedSame ? first.id < second.id : comparison == .orderedAscending
        }
    }

    private func sortGroups() {
        groups.sort { first, second in
            let firstPinned = conversationSettings(for: first.id).isPinned
            let secondPinned = conversationSettings(for: second.id).isPinned
            if firstPinned != secondPinned { return firstPinned }
            let comparison = displayName(for: first).localizedStandardCompare(displayName(for: second))
            return comparison == .orderedSame ? first.id < second.id : comparison == .orderedAscending
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
