import SwiftUI

/// Cross-session table view: every claude session the hub knows about,
/// plus historical transcripts found on disk. Sortable columns, three
/// filters (status / time / host), and a footer aggregate showing the
/// count + total cost across the filtered rows.
struct SessionsDashboardView: View {
    @EnvironmentObject private var catalog: SessionCatalog

    /// Default sort: most-recently-active at the top. The user can
    /// click any sortable column header to override.
    @State private var sortOrder: [KeyPathComparator<DashboardRow>] = [
        KeyPathComparator(\.lastActivityAt, order: .reverse)
    ]
    /// nil == "All"
    @State private var statusFilter: DashboardStatus?
    @State private var timeFilter: TimeRangeFilter = .all
    /// nil == "All" (matches any hostDisplayName)
    @State private var hostFilter: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 480)
        .task {
            if catalog.rows.isEmpty {
                await catalog.refresh()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                Task { await catalog.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(catalog.isLoading)
            .help("Re-scan all sessions on the machine")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 16) {
            Picker("Status", selection: $statusFilter) {
                Text("All").tag(Optional<DashboardStatus>.none)
                ForEach(DashboardStatus.allCases) { status in
                    Text(status.rawValue).tag(Optional(status))
                }
            }
            .frame(maxWidth: 200)
            Picker("Time", selection: $timeFilter) {
                ForEach(TimeRangeFilter.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .frame(maxWidth: 220)
            Picker("Host", selection: $hostFilter) {
                Text("All").tag(Optional<String>.none)
                ForEach(availableHosts, id: \.self) { host in
                    Text(host).tag(Optional(host))
                }
            }
            .frame(maxWidth: 220)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Distinct host names across the unfiltered row set. Sorted for
    /// deterministic Picker order. Driven off `catalog.rows` so adding
    /// a new host elsewhere refreshes the menu.
    private var availableHosts: [String] {
        Array(Set(catalog.rows.map(\.hostDisplayName))).sorted()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if catalog.isLoading && catalog.rows.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Scanning sessions…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            sessionsTable
        }
    }

    /// Apply filters first, then sort. Filter is a cheap O(n) pass;
    /// the sort runs over the (usually smaller) filtered set.
    private var filteredRows: [DashboardRow] {
        catalog.rows.filter { row in
            if let statusFilter, row.status != statusFilter { return false }
            if !timeFilter.includes(row.lastActivityAt) { return false }
            if let hostFilter, row.hostDisplayName != hostFilter { return false }
            return true
        }
    }

    private var sortedRows: [DashboardRow] {
        filteredRows.sorted(using: sortOrder)
    }

    private var sessionsTable: some View {
        Table(sortedRows, sortOrder: $sortOrder) {
            // Name absorbs the remaining width — explicit widths on
            // every other column let the narrow ones stay narrow
            // instead of expanding to equal-sized slots.
            TableColumn("Name", value: \.name)
            TableColumn("Host", value: \.hostDisplayName)
                .width(min: 100, ideal: 120)
            TableColumn("Status", value: \.status.sortRank) { row in
                Text(row.status.rawValue)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Started", value: \.createdAt) { row in
                Text(row.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 140, ideal: 150)
            TableColumn("Last activity", value: \.lastActivityAt) { row in
                Text(row.lastActivityAt.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 140, ideal: 150)
            TableColumn("Cost", value: \.cost) { row in
                Text(row.cost, format: .currency(code: "USD"))
            }
            .width(min: 70, ideal: 80)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        let rows = filteredRows
        let total = rows.reduce(0.0) { $0 + $1.cost }
        return HStack(spacing: 12) {
            Text("\(rows.count) session\(rows.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) {
                Text("Total:").foregroundStyle(.secondary)
                Text(total, format: .currency(code: "USD"))
                    .fontWeight(.medium)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Time-range filter for the dashboard. Matched against
/// `DashboardRow.lastActivityAt`.
enum TimeRangeFilter: String, CaseIterable, Identifiable {
    case all = "All time"
    case last30Days = "Last 30 days"
    case last7Days = "Last 7 days"

    var id: String { rawValue }

    func includes(_ date: Date) -> Bool {
        switch self {
        case .all: return true
        case .last30Days: return date > Date().addingTimeInterval(-30 * 24 * 3600)
        case .last7Days: return date > Date().addingTimeInterval(-7 * 24 * 3600)
        }
    }
}
