import Charts
import SwiftUI

/// Efficiency by average drive speed for the drives Stats loaded. Bins follow
/// the distance unit (10 mph or 15 km/h); a bin with few drives is drawn faint
/// and labelled sparse, and a bin with none stays an empty gap. Nothing is
/// smoothed or filled in.
struct SpeedEfficiencyCard: View {
    var drives: [DriveSummary]
    @Environment(\.units) private var units

    var body: some View {
        let bins = SpeedEfficiency.bins(drives, units: units)
        let used = bins.reduce(0) { $0 + $1.drives }
        if bins.isEmpty {
            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Efficiency by speed")
                    Text("Drives with a recorded average speed and energy will show how speed changes your efficiency.")
                        .font(.subheadline).foregroundStyle(ScreenKit.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                Card(padding: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Efficiency by speed", trailing: units.efficiencyUnit)
                        chart(bins)
                        Text("Average drive speed, \(speedUnit)")
                            .font(.caption).foregroundStyle(ScreenKit.tertiary)
                            .frame(maxWidth: .infinity)
                        HStack(spacing: 14) {
                            legend(ScreenKit.blue, "\(SpeedEfficiency.sparseBelow)+ drives")
                            legend(ScreenKit.blue.opacity(0.35), "Sparse, under \(SpeedEfficiency.sparseBelow)")
                        }
                        Text(caption(used: used))
                            .font(.footnote).foregroundStyle(ScreenKit.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ScreenKit.GroupCard(title: "By speed") {
                    ForEach(Array(bins.reversed().enumerated()), id: \.element.id) { index, bin in
                        ScreenKit.ValueRow(title: label(bin, withUnit: true), subtitle: subtitle(bin), showsDivider: index < bins.count - 1) {
                            Text(bin.whPerKm.map { units.formatEfficiency($0) } ?? "—")
                                .font(.callout.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(bin.isEmpty ? ScreenKit.tertiary : bin.isSparse ? ScreenKit.secondary : .white)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var speedUnit: String { units.distance == .miles ? "mph" : "km/h" }

    private func chart(_ bins: [SpeedEfficiency.Bin]) -> some View {
        let values = bins.compactMap { $0.whPerKm.map(units.efficiencyValue(whPerKm:)) }
        let top = (values.max() ?? 1) * 1.18
        return Chart(bins) { bin in
            if let wh = bin.whPerKm {
                let value = units.efficiencyValue(whPerKm: wh)
                // An x interval with one y draws a thin band, so each bin is a rectangle from zero.
                RectangleMark(xStart: .value("From", bin.lower + bin.width * 0.08), xEnd: .value("To", bin.upper - bin.width * 0.08),
                              yStart: .value("Zero", 0.0), yEnd: .value("Efficiency", value))
                    .foregroundStyle(bin.isSparse ? AnyShapeStyle(ScreenKit.blue.opacity(0.35)) : AnyShapeStyle(ScreenKit.blue.gradient))
                    .clipShape(.rect(cornerRadius: 4))
                    .annotation(position: .top, spacing: 3) {
                        Text("\(bin.drives)")
                            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(bin.isSparse ? ScreenKit.tertiary : ScreenKit.secondary)
                    }
                    .accessibilityLabel(label(bin, withUnit: true))
                    .accessibilityValue("\(units.formatEfficiency(wh)), \(drivesText(bin.drives))\(bin.isSparse ? ", sparse" : "")")
            }
        }
        .chartXScale(domain: (bins.first?.lower ?? 0)...(bins.last?.upper ?? 1))
        .chartYScale(domain: 0...max(top, 1))
        .chartXAxis {
            // The closing edge label sits left of its tick; centred, it would overflow the plot and be dropped.
            let edges = bins.map(\.lower) + [bins.last?.upper ?? 0]
            AxisMarks(values: edges) { value in
                AxisValueLabel(anchor: value.index == edges.count - 1 ? .topTrailing : .top)
                    .foregroundStyle(ScreenKit.secondary).font(.system(size: 10))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(ScreenKit.hairline)
                AxisValueLabel().foregroundStyle(ScreenKit.secondary).font(.system(size: 10))
            }
        }
        .frame(height: 190)
        .accessibilityLabel("Efficiency by average speed")
    }

    private func caption(used: Int) -> String {
        let skipped = drives.count - used
        var text = "Each bar is the energy over distance of the drives in that speed band; the number above it is the drive count."
        if skipped > 0 { text += " \(drivesText(skipped).capitalizedFirst) without a recorded speed or energy aren't included." }
        return text
    }

    private func subtitle(_ bin: SpeedEfficiency.Bin) -> String {
        if bin.isEmpty { return "No drives" }
        return drivesText(bin.drives) + (bin.isSparse ? " · sparse" : "")
    }

    private func drivesText(_ count: Int) -> String { "\(count) drive\(count == 1 ? "" : "s")" }

    private func label(_ bin: SpeedEfficiency.Bin, withUnit: Bool) -> String {
        let text = "\(VoltaFormat.number(bin.lower, digits: 0))–\(VoltaFormat.number(bin.upper, digits: 0))"
        return withUnit ? "\(text) \(speedUnit)" : text
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(label).font(.caption).foregroundStyle(ScreenKit.secondary)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

#Preview {
    ScrollView { SpeedEfficiencyCard(drives: []).padding() }.preferredColorScheme(.dark)
}
