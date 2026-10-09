import SwiftUI
import Charts
import AppKit

/// Adapts to the existing detail tile. Only supplied, known dates are plotted;
/// the display strings don't contain enough calendar information to fill gaps.
public struct AdaptiveLineChart: View {
    public let dataPoints: [DailySpendPoint]
    public let unit: String
    @State private var selectedPointID: String?

    public init(dataPoints: [DailySpendPoint], unit: String = "$") {
        self.dataPoints = dataPoints
        self.unit = unit
    }

    private var selectedIndex: Int? {
        dataPoints.firstIndex { $0.id == selectedPointID }
    }

    private var selectedPoint: DailySpendPoint? {
        selectedIndex.map { dataPoints[$0] }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dataPoints.isEmpty {
                Text("暂无可用趋势数据")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("未记录的消耗为未知，不是 0。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                if let selected = selectedPoint {
                    HStack(spacing: 6) {
                        Text("\(selected.dateString):")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(amountText(selected))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 4)
                    .accessibilityElement(children: .combine)
                }
                chart
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: dataPoints.map(\.id)) { _, ids in
            if let selectedPointID, !ids.contains(selectedPointID) {
                self.selectedPointID = nil
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(dataPoints) { point in
                // A single sample is a point, not a fabricated trend or area.
                if dataPoints.count > 1 {
                    LineMark(
                        x: .value("日期", point.dateString),
                        y: .value("消耗金额", point.amount)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .accessibilityHidden(true)

                    AreaMark(
                        x: .value("日期", point.dateString),
                        y: .value("消耗金额", point.amount)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(
                        colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .accessibilityHidden(true)
                }

                PointMark(
                    x: .value("日期", point.dateString),
                    y: .value("消耗金额", point.amount)
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(point.id == selectedPointID ? 64 : 32)
                .accessibilityLabel(point.dateString)
                .accessibilityValue(amountText(point))
            }
        }
        .chartXAxis {
            AxisMarks(values: axisDates) { _ in
                AxisValueLabel()
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    .foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondary.opacity(0.8))
            }
        }
        .chartYScale(range: .plotDimension(startPadding: 0, endPadding: 18))
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let plot = geometry[anchor]
                    let positions = dataPoints.map { proxy.position(forX: $0.dateString) }
                    let widths = dataPoints.map { labelWidth($0, availableWidth: plot.width) }
                    let labels = AdaptiveChartSelection.annotationIndices(
                        amounts: dataPoints.map(\.amount),
                        selectedIndex: selectedIndex,
                        positions: positions,
                        labelWidths: widths,
                        plotWidth: plot.width
                    )

                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .frame(width: plot.width, height: plot.height)
                            .offset(x: plot.minX, y: plot.minY)
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    select(at: value.location.x, positions: positions)
                                })
                            .accessibilityHidden(true)

                        ForEach(dataPoints.indices.filter { labels.contains($0) }, id: \.self) { index in
                            if let x = positions[index],
                               let y = proxy.position(forY: dataPoints[index].amount) {
                                Text(amountText(dataPoints[index]))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(index == selectedIndex ? Color.accentColor : Color.secondary)
                                    .lineLimit(1)
                                    .frame(width: widths[index])
                                    .position(
                                        x: plot.minX + AdaptiveChartSelection.labelCenter(x, width: widths[index], plotWidth: plot.width),
                                        y: plot.minY + min(max(8, y - 14), max(8, plot.height - 8))
                                    )
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
        }
        .help("点击或拖动选择已知日期；仅展示已记录数据，缺失日期不代表零消耗。")
        .accessibilityLabel("每日消耗趋势")
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint("可调整以选择前后日期；未记录日期为未知，不代表零消耗。")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: moveSelection(by: 1)
            case .decrement: moveSelection(by: -1)
            @unknown default: break
            }
        }
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: moveSelection(by: -1)
            case .right: moveSelection(by: 1)
            default: break
            }
        }
    }

    private var axisDates: [String] {
        let strideSize = max(1, Int(ceil(Double(dataPoints.count) / 5)))
        var indices = Array(stride(from: 0, to: dataPoints.count, by: strideSize))
        if let last = dataPoints.indices.last, indices.last != last { indices.append(last) }
        return indices.map { dataPoints[$0].dateString }
    }

    private var accessibilitySummary: String {
        guard let last = dataPoints.last else { return "暂无数据，未记录消耗为未知。" }
        let summary = "\(dataPoints.count)个已知日期，最后日期\(last.dateString)，消耗\(amountText(last))。"
        if let selected = selectedPoint {
            return summary + "已选择\(selected.dateString)，消耗\(amountText(selected))。"
        }
        return summary + (dataPoints.count == 1 ? "仅有一个数据点，尚不能判断趋势。" : "缺失日期不代表零消耗。")
    }

    private func amountText(_ point: DailySpendPoint) -> String {
        "\(unit)\(RelayNumberFormatter.decimal(point.amount))"
    }

    private func labelWidth(_ point: DailySpendPoint, availableWidth: CGFloat) -> CGFloat {
        let text = amountText(point) as NSString
        return min(max(0, availableWidth), ceil(text.size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold)
        ]).width) + 2)
    }

    private func select(at x: CGFloat, positions: [CGFloat?]) {
        guard let index = AdaptiveChartSelection.nearestIndex(to: x, positions: positions) else { return }
        selectedPointID = dataPoints[index].id
    }

    private func moveSelection(by offset: Int) {
        guard !dataPoints.isEmpty else { return }
        let index = selectedIndex.map { min(max(0, $0 + offset), dataPoints.count - 1) }
            ?? (offset > 0 ? 0 : dataPoints.count - 1)
        selectedPointID = dataPoints[index].id
    }
}

/// Pure layout/selection rules: real plot positions, stable extrema ties, no data synthesis.
/// Selected > last > maximum > minimum, with labels that collide omitted.
enum AdaptiveChartSelection {
    static func nearestIndex(to x: CGFloat, positions: [CGFloat?]) -> Int? {
        guard x.isFinite else { return nil }
        return positions.indices.filter { positions[$0]?.isFinite == true }.min {
            abs(positions[$0]! - x) < abs(positions[$1]! - x)
        }
    }

    static func labelCenter(_ x: CGFloat, width: CGFloat, plotWidth: CGFloat) -> CGFloat {
        min(max(width / 2, x), max(width / 2, plotWidth - width / 2))
    }

    static func annotationIndices(
        amounts: [Decimal], selectedIndex: Int?, positions: [CGFloat?],
        labelWidths: [CGFloat], plotWidth: CGFloat
    ) -> Set<Int> {
        guard !amounts.isEmpty, positions.count == amounts.count,
              labelWidths.count == amounts.count, plotWidth > 0 else { return [] }
        var candidates = [Int]()
        if let selectedIndex, amounts.indices.contains(selectedIndex) { candidates.append(selectedIndex) }
        candidates.append(amounts.count - 1)
        if let maximum = amounts.max(), let index = amounts.firstIndex(of: maximum) { candidates.append(index) }
        if let minimum = amounts.min(), let index = amounts.firstIndex(of: minimum) { candidates.append(index) }
        var accepted = Set<Int>()
        var ranges = [ClosedRange<CGFloat>]()
        for index in candidates where !accepted.contains(index) {
            guard let x = positions[index], x.isFinite else { continue }
            let width = labelWidths[index]
            guard width.isFinite, width > 0, width <= plotWidth else { continue }
            let center = labelCenter(x, width: width, plotWidth: plotWidth)
            let range = (center - width / 2)...(center + width / 2)
            guard !ranges.contains(where: { range.lowerBound < $0.upperBound + 6 && range.upperBound + 6 > $0.lowerBound }) else { continue }
            accepted.insert(index)
            ranges.append(range)
        }
        return accepted
    }
}
