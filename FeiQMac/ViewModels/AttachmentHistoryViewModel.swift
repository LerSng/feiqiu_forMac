import Combine
import Foundation

@MainActor
final class AttachmentHistoryViewModel: ObservableObject {
    typealias Search = (ChatAttachmentHistoryQuery, ChatAttachmentHistoryCursor?, Int,
                       @escaping (Result<ChatAttachmentHistoryPage, Error>) -> Void) -> Void

    @Published var query = ChatAttachmentHistoryQuery() {
        didSet {
            if query != oldValue, isActive { scheduleSearch(preservingResults: false) }
        }
    }
    @Published private(set) var results: [ChatAttachmentHistoryResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasMore = false
    @Published private(set) var errorMessage: String?

    private let search: Search
    private var isActive = false
    private var pendingSearch: Task<Void, Never>?
    private var generation = 0
    private var nextCursor: ChatAttachmentHistoryCursor?
    private var failedToLoadMore = false

    init(search: @escaping Search) {
        self.search = search
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        searchNow()
    }

    func stop() {
        isActive = false
        cancelPendingSearch()
    }

    func searchNow() {
        guard isActive else { return }
        resetSearch(preservingResults: false)
        loadPage(generation: generation, appending: false)
    }

    func refresh() {
        guard isActive else { return }
        scheduleSearch(preservingResults: true)
    }

    func loadMore() {
        guard isActive, hasMore, !isSearching else { return }
        loadPage(generation: generation, appending: true)
    }

    func retry() {
        if failedToLoadMore { loadMore() } else { searchNow() }
    }

    private func cancelPendingSearch() {
        pendingSearch?.cancel()
        pendingSearch = nil
        generation += 1
        isSearching = false
    }

    private func resetSearch(preservingResults: Bool) {
        cancelPendingSearch()
        if !preservingResults { results = [] }
        nextCursor = nil
        hasMore = false
        errorMessage = nil
        failedToLoadMore = false
    }

    private func scheduleSearch(preservingResults: Bool) {
        resetSearch(preservingResults: preservingResults)
        isSearching = true
        let requestGeneration = generation
        pendingSearch = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, self.generation == requestGeneration, self.isActive else { return }
            self.pendingSearch = nil
            self.loadPage(generation: requestGeneration, appending: false)
        }
    }

    private func loadPage(generation requestGeneration: Int, appending: Bool) {
        do {
            _ = try query.dateBounds()
        } catch {
            isSearching = false
            errorMessage = error.localizedDescription
            return
        }
        isSearching = true
        errorMessage = nil
        let requestCursor = appending ? nextCursor : nil
        search(query, requestCursor, 60) { [weak self] response in
            DispatchQueue.main.async {
                guard let self, self.isActive, self.generation == requestGeneration else { return }
                self.isSearching = false
                switch response {
                case .success(let page):
                    var identifiers = Set(appending ? self.results.map(\.id) : [])
                    let uniqueResults = page.results.filter { identifiers.insert($0.id).inserted }
                    self.results = appending ? self.results + uniqueResults : uniqueResults
                    self.nextCursor = page.nextCursor
                    self.hasMore = page.hasMore && page.nextCursor != nil && page.nextCursor != requestCursor
                    self.failedToLoadMore = false
                    if page.results.isEmpty, self.hasMore {
                        self.loadPage(generation: requestGeneration, appending: true)
                    }
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                    self.failedToLoadMore = appending
                }
            }
        }
    }
}
