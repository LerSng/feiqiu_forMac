import Combine
import Foundation

@MainActor
final class HistorySearchViewModel: ObservableObject, Identifiable {
    typealias Search = (ChatHistorySearchQuery, ChatHistorySearchCursor?, Int,
                       @escaping (Result<ChatHistorySearchPage, Error>) -> Void) -> Void

    let id = UUID()
    @Published var query: ChatHistorySearchQuery {
        didSet {
            if query != oldValue { scheduleSearch() }
        }
    }
    @Published private(set) var results: [ChatHistorySearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasMore = false
    @Published private(set) var errorMessage: String?

    private let search: Search
    private var pendingSearch: Task<Void, Never>?
    private var generation = 0
    private var nextCursor: ChatHistorySearchCursor?
    private var failedToLoadMore = false

    init(conversationID: String? = nil, search: @escaping Search) {
        self.query = ChatHistorySearchQuery(conversationID: conversationID)
        self.search = search
    }

    func searchNow() {
        resetSearch()
        loadPage(generation: generation, appending: false)
    }

    func loadMore() {
        guard hasMore, !isSearching else { return }
        loadPage(generation: generation, appending: true)
    }

    func retry() {
        if failedToLoadMore {
            loadMore()
        } else {
            searchNow()
        }
    }

    func cancel() {
        pendingSearch?.cancel()
        pendingSearch = nil
        generation += 1
        isSearching = false
    }

    private func resetSearch() {
        cancel()
        results = []
        nextCursor = nil
        hasMore = false
        errorMessage = nil
        failedToLoadMore = false
    }

    private func scheduleSearch() {
        resetSearch()
        isSearching = true
        let requestGeneration = generation
        pendingSearch = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, self.generation == requestGeneration else { return }
            self.loadPage(generation: requestGeneration, appending: false)
        }
    }

    private func loadPage(generation requestGeneration: Int, appending: Bool) {
        do {
            _ = try query.dateBounds()
        } catch {
            errorMessage = error.localizedDescription
            isSearching = false
            return
        }
        isSearching = true
        errorMessage = nil
        search(query, appending ? nextCursor : nil, 60) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == requestGeneration else { return }
                self.isSearching = false
                switch result {
                case .success(let page):
                    var identifiers = Set(appending ? self.results.map(\.id) : [])
                    let uniqueResults = page.results.filter { identifiers.insert($0.id).inserted }
                    self.results = appending ? self.results + uniqueResults : uniqueResults
                    self.nextCursor = page.results.last?.cursor
                    self.hasMore = page.hasMore && self.nextCursor != nil
                    self.failedToLoadMore = false
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                    self.failedToLoadMore = appending
                }
            }
        }
    }
}
