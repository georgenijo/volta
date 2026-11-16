import Synchronization
import SwiftUI
import UIKit

/// Export files live in their own temp subfolder so they can be swept: after the
/// share sheet closes, when leaving Data Management, on unpair, and at launch.
///
/// Every sweep starts a new generation. An export captures the generation when it
/// starts and may only write while that generation is still current; the check and
/// the write share a lock with the sweep, so a sweep can never be followed by a
/// stale write that recreates the file.
enum ExportFiles {
    struct StaleExportError: Error {}

    nonisolated private static let generation = Mutex<UInt64>(0)

    nonisolated static var directory: URL {
        FileManager.default.temporaryDirectory.appending(path: "volta-exports", directoryHint: .isDirectory)
    }

    /// Token for an export about to start; invalidated by the next `removeAll()`.
    nonisolated static func currentGeneration() -> UInt64 {
        generation.withLock { $0 }
    }

    nonisolated static func isCurrent(_ token: UInt64) -> Bool {
        generation.withLock { $0 == token }
    }

    /// Deletes every export and invalidates exports still being prepared.
    nonisolated static func removeAll() {
        generation.withLock { value in
            value &+= 1
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Replaces any previous export with `data`, only if no sweep happened since `token`.
    nonisolated static func write(_ data: Data, named name: String, token: UInt64) throws -> URL {
        try writeAll([(name, data)], token: token)[0]
    }

    /// Replaces any previous export with these files (one export can be several
    /// files, like the CSV tables), only if no sweep happened since `token`.
    nonisolated static func writeAll(_ files: [(name: String, data: Data)], token: UInt64) throws -> [URL] {
        try generation.withLock { value in
            guard value == token else { throw StaleExportError() }
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: directory)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return try files.map { file in
                let url = directory.appending(path: file.name)
                try file.data.write(to: url, options: [.atomic, .completeFileProtection])
                return url
            }
        }
    }
}

/// When Data Management must cancel preparation and delete exports, beyond
/// leaving the screen (`onDisappear`), which tab switches don't trigger.
enum ExportCleanup {
    nonisolated static func shouldSweep(isActiveTab: Bool, scenePhase: ScenePhase, isSharing: Bool) -> Bool {
        // Another shell tab was selected: the screen stays mounted but hidden.
        if !isActiveTab { return true }
        // Backgrounded: sweep, unless the share sheet is handing the file off.
        if scenePhase == .background { return !isSharing }
        return false
    }
}

struct ExportIncompleteError: LocalizedError {
    var errorDescription: String? {
        "Export stopped: the server returned more pages than Volta could load, so the file would be incomplete."
    }
}

/// Exports history on the phone and hands it to the share sheet: everything as
/// one JSON file, drives / charges / idles as CSV tables, or one drive's route
/// as GPX. Nothing is uploaded; the files are deleted once shared.
struct DataManagementView: View {
    enum Kind: Hashable, Sendable { case json, csv, gpx }

    struct Stat: Hashable, Sendable {
        var value: String
        var label: String
    }

    struct Export: Sendable {
        var kind: Kind
        /// A line above the stats, such as the drive a GPX file holds.
        var title: String? = nil
        var urls: [URL]
        var stats: [Stat]
        var bytes: Int
    }

    private struct Bundle: Encodable {
        var app = "Volta"
        var exportedAt: Date
        var vehicle: Vehicle?
        var drives: [DriveSummary]
        var charges: [ChargeSummary]
    }

    struct NoRouteError: LocalizedError {
        var errorDescription: String? { "This drive has no recorded route to export." }
    }

    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.isActiveTab) private var isActiveTab
    @Environment(\.scenePhase) private var scenePhase
    @State private var export: Export?
    @State private var preparing: Kind?
    @State private var errorMessage: String?
    @State private var isSharing = false
    @State private var choosingDrive = false
    /// The in-flight preparation, cancelled when the screen goes away.
    @State private var prepareTask: Task<Void, Never>?

    var body: some View {
        ScreenKit.Page(spacing: 24) {
            exportCard(.json, symbol: "square.and.arrow.up.on.square", title: "Export history",
                       subtitle: "All drives and charges as one JSON file, metric units.",
                       prepare: "Prepare export", footer: nil) { start(.json) }
            exportCard(.csv, symbol: "tablecells", title: "Spreadsheet (CSV)",
                       subtitle: "Drives, charges and idles as three CSV tables, metric units, times in UTC.",
                       prepare: "Prepare CSV files",
                       footer: "The tables include addresses and place names, but no coordinates. Unknown values are left blank.") { start(.csv) }
            exportCard(.gpx, symbol: "point.topleft.down.to.point.bottomright.curvepath", title: "Drive route (GPX)",
                       subtitle: "One drive's recorded route, for maps and GPS apps.",
                       prepare: "Choose a drive",
                       footer: "A GPX file contains the GPS coordinates of the whole route, including where it starts and ends. Share it only with people and apps you trust.") {
                choosingDrive = true
            }
            if let errorMessage {
                InlineBanner(systemImage: "exclamationmark.triangle", message: errorMessage, tint: ScreenKit.amber) { self.errorMessage = nil }
            }
            ScreenKit.GroupCard(title: "Where your data lives",
                                footer: "Exports are made on this iPhone and only leave it through the share sheet. Volta keeps no copy of your history beyond what's on screen.") {
                ScreenKit.ValueRow(title: "History", subtitle: "TeslaMate Postgres on your server") {
                    Image(systemName: "server.rack").foregroundStyle(ScreenKit.green)
                }
                ScreenKit.ValueRow(title: "Settings", subtitle: "This iPhone", showsDivider: false) {
                    Image(systemName: "iphone").foregroundStyle(ScreenKit.secondary)
                }
            }
        }
        .screenKitPage("Data Management", screen: "data-management")
        .sheet(isPresented: $isSharing, onDismiss: discardExport) {
            if let export {
                ActivityView(items: export.urls) { isSharing = false }
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $choosingDrive) {
            DrivePickerSheet { drive in
                choosingDrive = false
                start(.gpx, drive: drive)
            }
        }
        .onDisappear(perform: leave)
        .onChange(of: isActiveTab) { sweepIfNeeded() }
        .onChange(of: scenePhase) { sweepIfNeeded() }
    }

    // MARK: Cards

    private func exportCard(_ kind: Kind, symbol: String, title: String, subtitle: String, prepare: String,
                            footer: String?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol).font(.title3).foregroundStyle(ScreenKit.blue)
                            .frame(width: 28).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title).font(.headline).foregroundStyle(.white)
                            Text(subtitle).font(.footnote).foregroundStyle(ScreenKit.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let export, export.kind == kind {
                        if let title = export.title {
                            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 18) { stats(export) }
                            VStack(alignment: .leading, spacing: 6) { stats(export) }
                        }
                        .accessibilityElement(children: .combine)
                        Button { isSharing = true } label: {
                            Label(export.urls.count > 1 ? "Share \(export.urls.count) files" : kind == .gpx ? "Share GPX file" : "Share export",
                                  systemImage: "square.and.arrow.up")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(Color.voltaBlueFill, in: .rect(cornerRadius: VoltaRadius.wideButton, style: .continuous))
                        }
                        .buttonStyle(VoltaPressStyle())
                        .accessibilityIdentifier("button.export.share.\(slug(kind))")
                        if kind == .gpx {
                            Button("Choose another drive", action: action)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(ScreenKit.blue)
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("button.export.gpx.another")
                        }
                    } else {
                        PillButton(preparing == kind ? "Preparing…" : prepare, systemImage: kind == .gpx ? "list.bullet" : "doc.badge.arrow.up",
                                   size: .wide, style: .accent, isBusy: preparing == kind, action: action)
                            .disabled(preparing != nil)
                            .accessibilityIdentifier("button.export.\(slug(kind))")
                    }
                }
            }
            if let footer {
                Text(footer).font(.caption).foregroundStyle(ScreenKit.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func slug(_ kind: Kind) -> String {
        switch kind { case .json: "json"; case .csv: "csv"; case .gpx: "gpx" }
    }

    @ViewBuilder private func stats(_ export: Export) -> some View {
        ForEach(export.stats, id: \.self) { stat($0.value, $0.label) }
        stat(ByteCountFormatter.string(fromByteCount: Int64(export.bytes), countStyle: .file), "")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(.white).monospacedDigit()
            if !label.isEmpty { Text(label).font(.subheadline).foregroundStyle(ScreenKit.secondary) }
        }
    }

    // MARK: Lifecycle

    /// Shared or cancelled, the file is deleted; prepare again for another copy.
    private func discardExport() {
        export = nil
        ExportFiles.removeAll()
    }

    private func start(_ kind: Kind, drive: DriveSummary? = nil) {
        prepareTask?.cancel()
        errorMessage = nil
        // One export at a time: a new one replaces any file waiting to be shared.
        discardExport()
        // Captured before any request: unpair or leaving the screen sweeps exports
        // and bumps the generation, so this preparation can no longer write.
        let token = ExportFiles.currentGeneration()
        prepareTask = Task { await prepare(kind, drive: drive, token: token) }
    }

    private func sweepIfNeeded() {
        guard ExportCleanup.shouldSweep(isActiveTab: isActiveTab, scenePhase: scenePhase, isSharing: isSharing) else { return }
        isSharing = false
        leave()
    }

    private func leave() {
        prepareTask?.cancel()
        prepareTask = nil
        preparing = nil
        discardExport()
    }

    private func prepare(_ kind: Kind, drive: DriveSummary?, token: UInt64) async {
        preparing = kind
        defer { if !Task.isCancelled { preparing = nil } }
        let source = dataSource, id = vehicleID
        do {
            let prepared: Export
            switch kind {
            case .json: prepared = try await Self.prepareJSON(source: source, vehicleID: id, token: token)
            case .csv: prepared = try await Self.prepareCSV(source: source, vehicleID: id, token: token)
            case .gpx:
                guard let drive else { return }
                prepared = try await Self.prepareGPX(source: source, drive: drive, token: token)
            }
            // Left or unpaired while writing: the sweep already ran or the token is
            // stale, so drop the file rather than surface it.
            guard !Task.isCancelled, ExportFiles.isCurrent(token) else {
                if ExportFiles.isCurrent(token) { ExportFiles.removeAll() }
                return
            }
            export = prepared
        } catch is CancellationError {
        } catch is ExportFiles.StaleExportError {
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    /// Today's date on the phone (not UTC), for file names.
    private nonisolated static var stamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }

    private nonisolated static func prepareJSON(source: any VoltaDataSource, vehicleID id: Int, token: UInt64) async throws -> Export {
        let all = DateRange(from: nil, to: nil)
        async let drives = fetchAllPages { try await source.drives(vehicleID: id, range: all, cursor: $0) }
        async let charges = fetchAllPages { try await source.charges(vehicleID: id, range: all, cursor: $0) }
        let vehicle = try? await source.vehicles().first { $0.id == id }
        let (d, c) = try await (drives, charges)
        // Never hand out a file that looks complete but isn't.
        guard d.isComplete && c.isComplete else { throw ExportIncompleteError() }
        try Task.checkCancellation()
        let bundle = Bundle(exportedAt: .now, vehicle: vehicle, drives: d.items, charges: c.items)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        let url = try ExportFiles.write(data, named: "volta-export-\(stamp).json", token: token)
        return Export(kind: .json, urls: [url], stats: [Stat(value: "\(d.items.count)", label: "drives"),
                                                        Stat(value: "\(c.items.count)", label: "charges")], bytes: data.count)
    }

    private nonisolated static func prepareCSV(source: any VoltaDataSource, vehicleID id: Int, token: UInt64) async throws -> Export {
        let all = DateRange(from: nil, to: nil)
        async let drives = fetchAllPages { try await source.drives(vehicleID: id, range: all, cursor: $0) }
        async let charges = fetchAllPages { try await source.charges(vehicleID: id, range: all, cursor: $0) }
        async let idles = fetchAllPages { try await source.idles(vehicleID: id, range: all, cursor: $0) }
        let (d, c, i) = try await (drives, charges, idles)
        guard d.isComplete && c.isComplete && i.isComplete else { throw ExportIncompleteError() }
        try Task.checkCancellation()
        let day = stamp
        let files = [("volta-drives-\(day).csv", Data(CSVExport.drives(d.items).utf8)),
                     ("volta-charges-\(day).csv", Data(CSVExport.charges(c.items).utf8)),
                     ("volta-idles-\(day).csv", Data(CSVExport.idles(i.items).utf8))]
        let urls = try ExportFiles.writeAll(files.map { (name: $0.0, data: $0.1) }, token: token)
        return Export(kind: .csv, urls: urls, stats: [Stat(value: "\(d.items.count)", label: "drives"),
                                                      Stat(value: "\(c.items.count)", label: "charges"),
                                                      Stat(value: "\(i.items.count)", label: "idles")],
                      bytes: files.reduce(0) { $0 + $1.1.count })
    }

    private nonisolated static func prepareGPX(source: any VoltaDataSource, drive: DriveSummary, token: UInt64) async throws -> Export {
        let detail = try await source.drive(id: drive.id)
        try Task.checkCancellation()
        let points = GPXExport.points(detail).count
        guard let gpx = GPXExport.document(detail, name: GPXExport.name(for: drive)) else { throw NoRouteError() }
        let data = Data(gpx.utf8)
        let url = try ExportFiles.write(data, named: GPXExport.fileName(for: drive), token: token)
        return Export(kind: .gpx, title: "Drive on \(VoltaFormat.dateTime(drive.start))", urls: [url],
                      stats: [Stat(value: "\(points)", label: "points")], bytes: data.count)
    }
}

/// Recent drives to pick one route from, newest first, a page at a time.
private struct DrivePickerSheet: View {
    var onPick: (DriveSummary) -> Void

    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @Environment(\.dismiss) private var dismiss
    @State private var drives: [DriveSummary] = []
    @State private var cursor: String?
    @State private var phase: Loadable<Void> = .loading
    @State private var loadingMore = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    LoadableContent(state: phase, retry: { await load(reset: true) }) { _ in
                        if drives.isEmpty {
                            EmptyState(systemImage: "car", title: "No drives yet", message: "Recorded drives will appear here.")
                                .padding(.top, 60)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(drives.enumerated()), id: \.element.id) { index, drive in
                                    Button { onPick(drive) } label: {
                                        ScreenKit.ValueRow(title: VoltaFormat.dateTime(drive.start),
                                                           subtitle: route(drive), showsDivider: index < drives.count - 1) {
                                            Text(units.formatDistance(drive.distanceKm, fractionDigits: 1))
                                                .font(.subheadline).monospacedDigit().foregroundStyle(ScreenKit.secondary)
                                            ScreenKit.Chevron()
                                        }
                                    }
                                    .buttonStyle(VoltaPressStyle())
                                    .accessibilityIdentifier("row.export.drive.\(index)")
                                }
                            }
                            .voltaCardBackground()
                            if cursor != nil {
                                PillButton(loadingMore ? "Loading…" : "Load more", size: .wide, isBusy: loadingMore) {
                                    Task { await load(reset: false) }
                                }
                                .disabled(loadingMore)
                                .padding(.top, 16)
                            }
                        }
                    }
                }
                .padding(.horizontal, ScreenKit.horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(ScreenKit.background.ignoresSafeArea())
            .navigationTitle("Choose a drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ScreenKit.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationBackground(ScreenKit.background)
        .task { await load(reset: true) }
    }

    private func route(_ drive: DriveSummary) -> String {
        let from = drive.startCity ?? drive.startAddress.map(ChargePlace.firstComponent)
        let to = drive.endCity ?? drive.endAddress.map(ChargePlace.firstComponent)
        let places = [from, to].compactMap { $0 }
        return (places.isEmpty ? "" : places.joined(separator: " → ") + " · ") + VoltaFormat.duration(minutes: drive.durationMin)
    }

    private func load(reset: Bool) async {
        if reset { phase = .loading; drives = []; cursor = nil } else { loadingMore = true }
        defer { loadingMore = false }
        do {
            let page = try await dataSource.drives(vehicleID: vehicleID, range: DateRange(from: nil, to: nil), cursor: reset ? nil : cursor)
            drives += page.items.filter { new in !drives.contains { $0.id == new.id } }
            cursor = page.nextCursor
            phase = .loaded(())
        } catch is CancellationError {
        } catch {
            if reset { phase = .failed(error.localizedDescription) }
        }
    }
}

/// Share sheet with a completion callback (ShareLink has none), so the export
/// can be deleted as soon as it's shared or cancelled.
private struct ActivityView: UIViewControllerRepresentable {
    var items: [Any]
    var onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#Preview { NavigationStack { DataManagementView() }.voltaPreviewEnvironment() }
