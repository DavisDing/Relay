import SwiftUI
import Charts

/// A quiet summary of recorded days. Separate series leave unknown days empty;
/// monotone interpolation softens the line without inventing extra peaks.
struct RelaySpendSparkline: View {
    let values: [Decimal?]
    @Environment(\.colorSchemeContrast) private var contrast

    private struct Sample: Identifiable {
        let id: Int
        let amount: Double
        let segment: Int
    }

    private var samples: [Sample] {
        var segment = 0
        return values.enumerated().compactMap { index, amount in
            guard let amount, !amount.isNaN else { segment += 1; return nil }
            let value = NSDecimalNumber(decimal: amount).doubleValue
            guard value.isFinite else { segment += 1; return nil }
            return Sample(id: index, amount: value, segment: segment)
        }
    }

    var body: some View {
        let samples = samples
        let lower = min(0, samples.map(\.amount).min() ?? 0)
        let upper = max(0, samples.map(\.amount).max() ?? 0)
        let span = max(upper - lower, 1)
        let counts = Dictionary(grouping: samples, by: \.segment).mapValues(\.count)
        Chart {
            ForEach(samples) { sample in
                if counts[sample.segment, default: 0] > 1 {
                    AreaMark(x: .value("日期", sample.id), yStart: .value("基线", 0),
                        yEnd: .value("消费", sample.amount), series: .value("连续日期", sample.segment))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [.accentColor.opacity(0.16), .accentColor.opacity(0.01)],
                            startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("日期", sample.id), y: .value("消费", sample.amount),
                        series: .value("连续日期", sample.segment))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: contrast == .increased ? 2.2 : 1.8,
                            lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.accentColor)
                }
                if sample.id == samples.last?.id || counts[sample.segment] == 1 {
                    PointMark(x: .value("日期", sample.id), y: .value("消费", sample.amount))
                        .symbolSize(sample.id == samples.last?.id ? 20 : 10)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .chartXScale(domain: 0...max(1, values.count - 1), range: .plotDimension(startPadding: 4, endPadding: 4))
        .chartYScale(domain: (lower - (lower < 0 ? span * 0.1 : 0))...(upper + span * 0.15))
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.background(alignment: .bottom) {
                Rectangle().fill(Color.secondary.opacity(0.12)).frame(height: 0.5)
            }
        }
        .overlay {
            if samples.isEmpty { Text("暂无趋势").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
