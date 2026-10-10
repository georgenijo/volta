import Foundation
import Observation

/// Cursor-paginated list state shared by the three history screens.
///
/// Refresh and pagination are separate state machines:
/// - A refresh (`reload`) blocks pagination while it runs and invalidates any
///   outstanding page request, so a stale page can never append to, or
///   overwrite the cursor of, the refreshed list.
/// - The refreshed items, cursor and query are installed together only when
///   the first page arrives. A failed refresh keeps the previous rows *and*
///   the query that produced their cursor.
/// - `paginationTrigger` deliberately excludes `isLoadingMore`, so starting a
///   page load never changes the identity the footer's `.task(id:)` keys on
///   (which would cancel the request it just started).
@MainActor @Observable
final class HistoryFeed<Item: Codable & Hashable & Sendable & Identifiable> {
    typealias Fetch = @Sendable (DateRange, String?) async throws -> Page<Item>

    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// Footer `.task(id:)` key. Changes when a new cursor is installed or
    /// pagination becomes (un)blocked; never when a page load starts.
    struct PaginationTrigger: Hashable {
        var cursor: String?
        var blocked: Bool
    }

    private(set) var items: [Item] = []
    private(set) var phase: Phase = .loading
    private(set) var nextCursor: String?
    private(set) var isRefreshing = false
    private(set) var isLoadingMore = false
    private(set) var loadMoreError: String?
    /// A pull-to-refresh that failed while older rows stayed visible.
    private(set) var refreshError: String?

    /// Bumped by every reload; invalidates in-flight reloads.
    private var listGeneration = 0
    /// Bumped by every reload and page request; invalidates in-flight pages.
    private var pageGeneration = 0
    /// Query that produced `items` and `nextCursor`.
    private(set) var range = DateRange(from: nil, to: nil)
    private var fetch: Fetch?

    var hasMore: Bool { nextCursor != nil }

    var canLoadMore: Bool {
        phase == .loaded && nextCursor != nil && fetch != nil
            && !isRefreshing && !isLoadingMore && loadMoreError == nil
    }

    var paginationTrigger: PaginationTrigger {
        PaginationTrigger(cursor: nextCursor,
                          blocked: phase != .loaded || isRefreshing || loadMoreError != nil)
    }

    /// Error to surface at the list footer, if any.
    var footerError: String? { refreshError ?? loadMoreError }

    /// Replaces the list. Keeps existing rows visible during pull-to-refresh;
    /// shows skeletons only when asked or when there is nothing to show yet.
    func reload(range newRange: DateRange, fetch newFetch: @escaping Fetch, showSkeleton: Bool = false) async {
        listGeneration += 1
        pageGeneration += 1  // drop any outstanding page request
        let token = listGeneration
        isLoadingMore = false
        isRefreshing = true
        if showSkeleton || items.isEmpty { phase = .loading }
        do {
            let page = try await newFetch(newRange, nil)
            guard token == listGeneration else { return }
            // Install the new list, its cursor and its query together.
            range = newRange
            fetch = newFetch
            items = page.items
            nextCursor = page.nextCursor
            loadMoreError = nil
            refreshError = nil
            phase = .loaded
            isRefreshing = false
        } catch {
            guard token == listGeneration else { return }
            isRefreshing = false
            if error is CancellationError || Task.isCancelled {
                // Superseded by the view going away; a reappearing view reloads.
                return
            }
            if showSkeleton || items.isEmpty || phase != .loaded {
                items = []
                nextCursor = nil
                fetch = nil
                loadMoreError = nil
                refreshError = nil
                phase = .failed(error.localizedDescription)
            } else {
                // Keep stale rows and the query that matches their cursor.
                refreshError = error.localizedDescription
            }
        }
    }

    /// Loads the page after `nextCursor`. No-op while refreshing, while a page
    /// is already loading, after a page error (use `retryLoadMore`), or at the end.
    func loadMore() async {
        guard canLoadMore, let fetch, let cursor = nextCursor else { return }
        pageGeneration += 1
        let token = pageGeneration
        let query = range
        isLoadingMore = true
        do {
            let page = try await fetch(query, cursor)
            guard token == pageGeneration else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            nextCursor = page.nextCursor
            isLoadingMore = false
        } catch {
            guard token == pageGeneration else { return }
            isLoadingMore = false
            if error is CancellationError || Task.isCancelled { return }
            loadMoreError = error.localizedDescription
        }
    }

    func retryLoadMore() async {
        loadMoreError = nil
        await loadMore()
    }
}
