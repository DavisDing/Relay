import SwiftUI
import Charts

/// 完全自适应宽高的折线趋势图组件
/// 仅面向 macOS 27+：采用系统原生 Swift Charts，支持渐变面积图、点选悬浮交互与动态自适应
public struct AdaptiveLineChart: View {
    public let dataPoints: [DailySpendPoint]
    public let unit: String
    @State private var selectedPoint: DailySpendPoint? = nil
    
    public init(dataPoints: [DailySpendPoint], unit: String = "$") {
        self.dataPoints = dataPoints
        self.unit = unit
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 选点或峰值提示条
            if let selected = selectedPoint {
                HStack(spacing: 6) {
                    Text("\(selected.dateString):")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("\(unit)\(RelayNumberFormatter.decimal(selected.amount))")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 4)
            }
            
            Chart {
                ForEach(dataPoints) { pt in
                    // 1. 平滑折线
                    LineMark(
                        x: .value("日期", pt.dateString),
                        y: .value("消耗金额", pt.amount)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    
                    // 2. 半透明渐变面积
                    AreaMark(
                        x: .value("日期", pt.dateString),
                        y: .value("消耗金额", pt.amount)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.35),
                                Color.accentColor.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    
                    // 3. 关键打点与数值标注
                    PointMark(
                        x: .value("日期", pt.dateString),
                        y: .value("消耗金额", pt.amount)
                    )
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(32)
                    .annotation(position: .top, spacing: 4) {
                        Text("\(unit)\(RelayNumberFormatter.decimal(pt.amount))")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { _ in
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
