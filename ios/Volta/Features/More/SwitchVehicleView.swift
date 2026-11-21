import SwiftUI

/// Lists the account's vehicles; tapping one sets AppModel's persisted selection,
/// which re-keys the app environment (`\.vehicleID`) for every screen.
struct SwitchVehicleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @State private var state: Loadable<[Vehicle]> = .loading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScreenKit.Page {
            LoadableContent(state: state, retry: load, errorTitle: "Couldn't load vehicles") { vehicles in
                if vehicles.isEmpty {
                    EmptyState(systemImage: "car", title: "No vehicles",
                               message: "TeslaMate hasn't reported a vehicle to your server yet. Cars appear here once TeslaMate logs them.")
                } else {
                    VStack(spacing: 18) {
                        ScreenKit.GroupCard(title: "Vehicles",
                                            footer: model.isLaunchDemo ? "Launch demo shows a fixed vehicle; selection isn't saved."
                                                : vehicles.count == 1 ? "Vehicles come from TeslaMate. Add another car there and it appears here." : nil) {
                            ForEach(Array(vehicles.enumerated()), id: \.element.id) { index, vehicle in
                                Button {
                                    model.selectedVehicleID = vehicle.id
                                } label: {
                                    ScreenKit.ValueRow(title: vehicle.name,
                                                       subtitle: VehicleInfoSheet.detail(vehicle),
                                                       showsDivider: index < vehicles.count - 1) {
                                        if vehicle.id == model.selectedVehicleID {
                                            // Blue: the selection.
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(ScreenKit.blue)
                                                .transition(.symbolEffect(.appear))
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(vehicle.id == model.selectedVehicleID ? .isSelected : [])
                            }
                        }
                    }
                    .padding(.top, 4)
                    .voltaFocusIn()
                    .animation(VoltaMotion.animation(VoltaMotion.pop, reduceMotion: reduceMotion), value: model.selectedVehicleID)
                    .voltaFeedback(.selection, trigger: model.selectedVehicleID)
                }
            }
        }
        .screenKitPage("Switch vehicle")
        .task(id: vehicleID) { await load() }
    }

    private func load() async {
        // Prefer the vehicles AppModel already loaded; fall back to the data source (demo).
        if !model.vehicles.isEmpty { state = .loaded(model.vehicles); return }
        do { state = .loaded(try await dataSource.vehicles()) }
        catch is CancellationError {}
        catch { state = .failed(error.localizedDescription) }
    }
}

#Preview {
    NavigationStack { SwitchVehicleView() }.voltaPreviewEnvironment()
}
