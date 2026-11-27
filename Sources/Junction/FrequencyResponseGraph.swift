import Charts
import JunctionCore
import SwiftUI

/// One curve on a frequency response graph: levels in dB at frequencies in Hz.
struct ResponseCurve: Identifiable {
    var name: String
    var color: Color
    var frequencies: [Double]
    var levels: [Double]
    /// Drawn dashed (a target, or a curve for reference).
    var isDashed = false
    /// Thinner and fainter: one of many (a single measurement behind its average).
    var isFaint = false

    var id: String { name }
}

/// Frequency responses on a logarithmic axis from 20 Hz to 20 kHz with a dB axis that fits the curves (at least
/// ±6 dB), each curve named in the legend. Colours come from the caller; the grid and labels follow the appearance.
struct FrequencyResponseGraph: View {
    let curves: [ResponseCurve]
    var height: CGFloat = 150
    /// What VoiceOver calls it; the value lists the curves.
    var accessibilityTitle = "Frequency response"

    private static let ticks: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]

    var body: some View {
        let range = levelRange
        Chart {
            RuleMark(y: .value("dB", 0))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 0.5))
            ForEach(curves) { curve in
                ForEach(Self.points(of: curve, in: range)) { point in
                    Self.mark(point, of: curve)
                }
            }
        }
        .chartForegroundStyleScale(domain: curves.map(\.name), range: curves.map(\.color))
        .chartXScale(domain: 20...20_000, type: .log)
        .chartYScale(domain: range)
        .chartXAxis {
            AxisMarks(values: Self.ticks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let hertz = value.as(Double.self) { Text(Self.label(hertz)).font(.system(size: 9)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let dB = value.as(Double.self) { Text("\(Int(dB.rounded()))").font(.system(size: 9)) }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
        .frame(height: height)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(curves.map(\.name).joined(separator: ", "))
    }

    /// One point of a curve, its level clamped to the graph's range.
    private struct Point: Identifiable {
        let id: Int
        let frequency: Double
        let level: Double
    }

    // Built in small typed steps: as one expression inside the Chart, older compilers time out type-checking it.
    private static func points(of curve: ResponseCurve, in range: ClosedRange<Double>) -> [Point] {
        let pairs: [(Double, Double)] = Array(zip(curve.frequencies, curve.levels))
        var points: [Point] = []
        points.reserveCapacity(pairs.count)
        for (index, pair) in pairs.enumerated() {
            let level: Double = min(max(pair.1, range.lowerBound), range.upperBound)
            points.append(Point(id: index, frequency: pair.0, level: level))
        }
        return points
    }

    private static func mark(_ point: Point, of curve: ResponseCurve) -> some ChartContent {
        let width: CGFloat = curve.isFaint ? 0.75 : 1.5
        let dash: [CGFloat] = curve.isDashed ? [4, 3] : []
        let opacity: Double = curve.isFaint ? 0.45 : 1
        let x: PlottableValue<Double> = .value("Frequency", point.frequency)
        let y: PlottableValue<Double> = .value("Level", point.level)
        let series: PlottableValue<String> = .value("Curve", curve.name)
        return LineMark(x: x, y: y, series: series)
            .foregroundStyle(by: series)
            .lineStyle(StrokeStyle(lineWidth: width, dash: dash))
            .opacity(opacity)
            .interpolationMethod(.monotone)
    }

    /// The curves' extent, rounded out to 3 dB and at least ±6 dB.
    private var levelRange: ClosedRange<Double> {
        let levels = curves.flatMap(\.levels).filter(\.isFinite)
        let low = min(-6, floor(((levels.min() ?? 0) - 1) / 3) * 3)
        let high = max(6, ceil(((levels.max() ?? 0) + 1) / 3) * 3)
        return max(low, -48)...min(high, 24)
    }

    /// "20", "500", "1k", "20k".
    static func label(_ hertz: Double) -> String {
        hertz >= 1000 ? "\(Int(hertz / 1000))k" : "\(Int(hertz))"
    }
}
