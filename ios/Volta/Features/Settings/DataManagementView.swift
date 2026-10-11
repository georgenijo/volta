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
        try generation.withLock { value in
            guard value == token else { throw StaleExportError() }
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: directory)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: name)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
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

/// Exports drives and charges as JSON via the share sheet.
struct DataManagementView: View {
    struct Export: Sendable {
        var url: URL
        var drives: Int
        var charges: Int
        var bytes: Int
    }

    private struct Bundle: Encodable {
        var app = "Volta"
        var exportedAt: Date
        var vehicle: Vehicle?
        var drives: [DriveSummary]
        var charges: [ChargeSummary]
    }

    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.isActiveTab) private var isActiveTab
    @Environment(\.scenePhase) private var scenePhase
    @State private var export: Export?
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var isSharing = false
    /// The in-flight preparation, cancelled when the screen goes away.
    @State private var prepareTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Card(padding: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: "square.and.arrow.up.on.square").font(.system(size: 22)).foregroundStyle(ScreenKit.blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Export history").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                                Text("All drives and charges as one JSON file, metric units.")
                                    .font(.system(size: 13)).foregroundStyle(ScreenKit.secondary)
                            }
                        }
                        if let export {
                            HStack(spacing: 18) {
                                stat("\(export.drives)", "drives")
                                stat("\(export.charges)", "charges")
                                stat(ByteCountFormatter.string(fromByteCount: Int64(export.bytes), countStyle: .file), "")
                            }
                            Button { isSharing = true } label: {
                                Label("Share export", systemImage: "square.and.arrow.up")
                                    .font(.system(.callout, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 15)
                                    .background(Color.voltaBlue, in: .rect(cornerRadius: VoltaRadius.wideButton, style: .continuous))
                            }
                            .buttonStyle(VoltaPressStyle())
                        } else {
                            PillButton(isExporting ? "Preparing…" : "Prepare export", systemImage: "doc.badge.arrow.up",
                                       size: .wide, style: .accent, isBusy: isExporting) {
                                startExport()
                            }
                            .disabled(isExporting)
                        }
                    }
                }
                if let errorMessage {
                    InlineBanner(systemImage: "exclamationmark.triangle", message: errorMessage, tint: ScreenKit.amber) { self.errorMessage = nil }
                }
                ScreenKit.GroupCard(title: "Where your data lives",
                                    footer: "Volta keeps no copy of your history on this iPhone beyond what's on screen.") {
                    ScreenKit.ValueRow(title: "History", subtitle: "TeslaMate Postgres on your server") {
                        Image(systemName: "server.rack").foregroundStyle(ScreenKit.green)
                    }
                    ScreenKit.ValueRow(title: "Settings", subtitle: "This iPhone", showsDivider: false) {
                        Image(systemName: "iphone").foregroundStyle(ScreenKit.secondary)
                    }
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .screenKitPage("Data Management")
        .sheet(isPresented: $isSharing, onDismiss: discardExport) {
            if let export {
                ActivityView(items: [export.url]) { isSharing = false }
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
        }
        .onDisappear(perform: leave)
        .onChange(of: isActiveTab) { sweepIfNeeded() }
        .onChange(of: scenePhase) { sweepIfNeeded() }
    }

    /// Shared or cancelled, the file is deleted; prepare again for another copy.
    private func discardExport() {
        export = nil
        ExportFiles.removeAll()
    }

    private func startExport() {
        prepareTask?.cancel()
        // Captured before any request: unpair or leaving the screen sweeps exports
        // and bumps the generation, so this preparation can no longer write.
        let token = ExportFiles.currentGeneration()
        prepareTask = Task { await prepare(token: token) }
    }

    private func sweepIfNeeded() {
        guard ExportCleanup.shouldSweep(isActiveTab: isActiveTab, scenePhase: scenePhase, isSharing: isSharing) else { return }
        isSharing = false
        leave()
    }

    private func leave() {
        prepareTask?.cancel()
        prepareTask = nil
        isExporting = false
        discardExport()
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).monospacedDigit()
            if !label.isEmpty { Text(label).font(.system(size: 14)).foregroundStyle(ScreenKit.secondary) }
        }
    }

    private func prepare(token: UInt64) async {
        isExporting = true
        defer { if !Task.isCancelled { isExporting = false } }
        let source = dataSource, id = vehicleID
        do {
            let all = DateRange(from: nil, to: nil)
            async let drives = fetchAllPages { try await source.drives(vehicleID: id, range: all, cursor: $0) }
            async let charges = fetchAllPages { try await source.charges(vehicleID: id, range: all, cursor: $0) }
            let vehicle = try? await source.vehicles().first { $0.id == id }
            let (d, c) = try await (drives, charges)
            // Never hand out a file that looks complete but isn't.
            guard d.isComplete && c.isComplete else { throw ExportIncompleteError() }
            try Task.checkCancellation()
            let prepared = try await Self.write(Bundle(exportedAt: .now, vehicle: vehicle, drives: d.items, charges: c.items), token: token)
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

    private nonisolated static func write(_ bundle: Bundle, token: UInt64) async throws -> Export {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        let stamp = bundle.exportedAt.formatted(.iso8601.year().month().day())
        let url = try ExportFiles.write(data, named: "volta-export-\(stamp).json", token: token)
        return Export(url: url, drives: bundle.drives.count, charges: bundle.charges.count, bytes: data.count)
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
