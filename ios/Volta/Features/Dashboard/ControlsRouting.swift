import Foundation

/// The rules for where the Dashboard shows Controls and what opens or closes
/// them. Pure, so each rule is unit tested; `DashboardView` and `MainShell`
/// only call these and keep the state.
///
/// `wantsControls` is the Dashboard's `showControls`: Controls are open as far
/// as the user is concerned, whether or not they are on screen right now.
@MainActor
enum ControlsRouting {
    /// Where open Controls are shown now. Pushed Controls are inside the root,
    /// under its privacy shield and lock overlay, so they stay while locked. A
    /// sheet sits above the root, so it is never shown while locked: Controls
    /// open in a sheet layout (for example after folding while locked) wait,
    /// and appear in the sheet once the app is unlocked.
    static func host(wantsControls: Bool, pushedLayout: Bool, locked: Bool) -> ControlsView.Presentation? {
        guard wantsControls else { return nil }
        if pushedLayout { return .pushed }
        return locked ? nil : .sheet
    }

    /// Whether Controls stay open when the app locks with them in `host`. A
    /// sheet on screen closes; pushed Controls stay, behind the lock overlay.
    static func keepsControlsOnLock(host: ControlsView.Presentation?) -> Bool {
        host != .sheet
    }

    /// Whether Controls stay open after the user cancels (or fails) an unlock.
    /// Controls the lock is hiding close, so a later unlock doesn't bring them
    /// back unasked; pushed Controls are still where they were.
    static func keepsControlsAfterRefusedUnlock(host: ControlsView.Presentation?) -> Bool {
        host == .pushed
    }

    /// The Dashboard's response to the lock control's request (see
    /// `AppModel.controlsPresentationRequested`): true, once per request, when
    /// it should open Controls. Called when the Dashboard appears too, so a
    /// request made before it was built (a cold launch) is not lost.
    static func opensControlsForRequest(_ app: AppModel?) -> Bool {
        app?.takeControlsPresentation() == true
    }

    /// The shell's tab while a request to open Controls is pending: the
    /// Dashboard, which owns Controls.
    static func shellTab(requested: Bool, current: MainShell.Tab) -> MainShell.Tab {
        requested ? .dashboard : current
    }
}
