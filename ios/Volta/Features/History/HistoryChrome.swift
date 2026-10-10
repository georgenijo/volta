import SwiftUI

// MARK: - Header

/// Top bar from the references: range pill (with optional filter menu) on the
/// left, centered title, a group of circular glass buttons on the right.
struct HistoryHeader<Filter: View, Trailing: View>: View {
    var title: String
    @Binding var range: HistoryRange
    var filterActive: Bool
    @ViewBuilder var filterMenu: Filter
    @ViewBuilder var trailing: Trailing

    @State private var showingCustomRange = false

    var body: some View {
        VoltaHeader(title) {
            GlassPill(height: 48) { rangeControls }
        } trailing: {
            GlassPill(height: 48) { trailing }
        }
        .padding(.bottom, 6)
        .sheet(isPresented: $showingCustomRange) {
            CustomRangeSheet(range: $range)
                .presentationDetents([.medium])
                .presentationBackground(HistoryTheme.card)
        }
    }

    private var rangeControls: some View {
        HStack(spacing: 18) {
            Menu {
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.presets, id: \.self) { preset in
                        Text(preset.menuTitle).tag(preset)
                    }
                }
                Divider()
                Button("Custom range…", systemImage: "calendar") { showingCustomRange = true }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
                    Text(range.label)
                        .font(.system(size: 17, weight: .semibold))
                        .monospacedDigit()
                }
                .frame(height: 48)
                .contentShape(.rect)
            }
            .accessibilityLabel("Date range, \(range.menuTitle)")
            if Filter.self != EmptyView.self {
                Menu {
                    filterMenu
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(filterActive ? HistoryTheme.blue : .white)
                        .shadow(color: filterActive ? HistoryTheme.blue.opacity(0.7) : .clear, radius: 6)
                        .frame(height: 48)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Filter")
            }
        }
    }
}

/// Icon button meant to live inside the header's trailing glass capsule.
struct HistoryHeaderButton: View {
    var systemImage: String
    var label: String
    var isOn: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(isOn ? HistoryTheme.blue : .white)
                .shadow(color: isOn ? HistoryTheme.blue.opacity(0.7) : .clear, radius: 6)
                .frame(minWidth: 28, minHeight: 48)
                .contentShape(.rect)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(label)
    }
}

private struct CustomRangeSheet: View {
    @Binding var range: HistoryRange
    @Environment(\.dismiss) private var dismiss
    @State private var from = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .now
    @State private var to = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HistorySectionLabel(title: "Custom range")
            DatePicker("From", selection: $from, in: ...to, displayedComponents: .date)
            DatePicker("To", selection: $to, in: from...Date.now, displayedComponents: .date)
            Spacer()
            Button {
                range = .custom(from: from, to: to)
                dismiss()
            } label: {
                Text("Apply")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.glassProminent)
            .tint(HistoryTheme.blue)
        }
        .foregroundStyle(.white)
        .padding(24)
        .onAppear {
            if case .custom(let f, let t) = range { from = f; to = t }
        }
    }
}

// MARK: - Search

struct HistorySearchField: View {
    @Binding var text: String
    var prompt: String
    var onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HistoryTheme.tertiary)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .foregroundStyle(.white)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(HistoryTheme.tertiary)
                }
                .buttonStyle(.plain)
            }
            Button("Cancel") { text = ""; onClose() }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HistoryTheme.blue)
                .buttonStyle(.plain)
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(LinearGradient(colors: [Color.voltaCardTop, Color.voltaCard], startPoint: .top, endPoint: .bottom), in: .capsule)
        .overlay {
            Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                                   lineWidth: 1)
        }
        .padding(.horizontal, HistoryTheme.gutter)
        .padding(.bottom, 8)
        .onAppear { focused = true }
    }
}

// MARK: - States

/// Empty state placed like the references: left-aligned, a little above
/// center, with an optional action underneath.
struct HistoryEmptyState: View {
    var systemImage: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 0)
            EmptyState(systemImage: systemImage, title: title, message: message)
            if let actionTitle, let action {
                PillButton(actionTitle, systemImage: "arrow.clockwise", action: action)
                    .padding(.horizontal, VoltaSpacing.xl + VoltaSpacing.xs)
            }
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.bottom, 40)
    }
}

struct HistoryErrorState: View {
    var title: String
    var message: String
    var retry: () -> Void

    var body: some View {
        HistoryEmptyState(systemImage: "wifi.exclamationmark", title: title, message: message,
                          actionTitle: "Try again", action: retry)
    }
}

/// Pulsing placeholder blocks shown while the first page loads.
struct HistorySkeletonList: View {
    var rows: Int = 5
    @State private var pulse = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(spacing: 8) {
                            bar(width: 70, height: 26)
                            bar(width: 50, height: 9)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 14)
                bar(width: 80, height: 10).padding(.top, 8)
                ForEach(0..<rows, id: \.self) { _ in
                    HistoryCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.06)).frame(width: 38, height: 38)
                                VStack(alignment: .leading, spacing: 7) {
                                    bar(width: 150, height: 13)
                                    bar(width: 100, height: 10)
                                }
                                Spacer()
                                bar(width: 46, height: 14)
                            }
                            bar(width: nil, height: 6)
                            HStack(spacing: 18) {
                                bar(width: 60, height: 11)
                                bar(width: 50, height: 11)
                                bar(width: 56, height: 11)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, HistoryTheme.gutter)
        }
        .scrollDisabled(true)
        .opacity(pulse ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityLabel("Loading")
    }

    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(Color.white.opacity(0.06))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
    }
}

/// Bottom of a paginated list. Loads the next page while visible.
///
/// The container's identity never depends on loading state; the load is keyed
/// on the feed's `paginationTrigger` (cursor + blocked), which does not change
/// when a request starts, so the request is never cancelled by its own state.
struct HistoryPageFooter<Item: Codable & Hashable & Sendable & Identifiable>: View {
    var feed: HistoryFeed<Item>
    /// Retries a failed pull-to-refresh (page errors retry in place).
    var retryRefresh: () async -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let error = feed.footerError {
                Text(error)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(HistoryTheme.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task {
                        if feed.refreshError != nil { await retryRefresh() } else { await feed.retryLoadMore() }
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HistoryTheme.blue)
                .buttonStyle(.plain)
            } else if feed.hasMore {
                ProgressView()
                    .tint(HistoryTheme.secondary)
                    .accessibilityLabel("Loading more")
            } else {
                Text("That's everything")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.3)
                    .textCase(.uppercase)
                    .foregroundStyle(HistoryTheme.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .task(id: feed.paginationTrigger) { await feed.loadMore() }
    }
}

// MARK: - Totals

/// Totals header: scope heading ("Last 30 days", or "Loaded drives — partial"
/// when more pages exist), the totals row and any coverage notes.
struct HistoryTotalsBlock: View {
    var title: String
    var isPartial: Bool
    var items: [HistoryTotalsRow.Item]
    var notes: [String] = []

    var body: some View {
        VStack(spacing: 12) {
            HistorySectionLabel(title: title, systemImage: isPartial ? "circle.dashed" : nil)
            HistoryTotalsRow(items: items)
            if !notes.isEmpty {
                VStack(spacing: 3) {
                    ForEach(notes, id: \.self) { note in
                        Text(note)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(HistoryTheme.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
            HairlineDivider()
        }
        .padding(.top, 8)
    }
}
