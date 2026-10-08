import SwiftUI
import WidgetKit

struct VoltaEntry: TimelineEntry {
    var date: Date
    /// nil means the app has not written a snapshot yet (not paired / first launch).
    var snapshot: WidgetSnapshot?
}

/// Reads the snapshot the app writes to the App Group container.
///
/// The app is the source of truth: it calls `WidgetSnapshotStore.write(...)` +
/// `WidgetCenter.shared.reloadAllTimelines()` after every refresh. The provider
/// itself only asks WidgetKit to come back periodically so relative "updated"
/// labels and stale styling stay honest. A widget-side network refresh (shared
/// keychain token -> volta-api) is documented in README.md but not enabled.
struct VoltaProvider: TimelineProvider {
    func placeholder(in context: Context) -> VoltaEntry {
        VoltaEntry(date: .now, snapshot: .fixture())
    }

    func getSnapshot(in context: Context, completion: @escaping (VoltaEntry) -> Void) {
        let stored = WidgetSnapshotStore.read()
        // The widget gallery shows the fixture when nothing is stored yet.
        completion(VoltaEntry(date: .now, snapshot: stored ?? (context.isPreview ? .fixture() : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VoltaEntry>) -> Void) {
        let now = Date.now
        let snapshot = WidgetSnapshotStore.read()
        // Regular entries so "Updated … ago" advances, plus one at the moment
        // the data turns stale so stale styling appears on time.
        let dates = WidgetSnapshot.timelineDates(now: now, snapshot: snapshot)
        let entries = dates.map { VoltaEntry(date: $0, snapshot: snapshot) }
        let step: TimeInterval = snapshot?.isCharging == true ? 5 * 60 : 10 * 60
        completion(Timeline(entries: entries, policy: .after((dates.last ?? now).addingTimeInterval(step))))
    }
}
