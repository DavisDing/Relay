import Foundation
import Darwin

/// Standalone checks, following the project's executable contract-test convention.
@main
private enum AdaptiveLineChartChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func labels(_ amounts: [Decimal], selected: Int? = nil,
                       positions: [CGFloat?]? = nil, widths: [CGFloat]? = nil,
                       plotWidth: CGFloat = 400) -> Set<Int> {
        AdaptiveChartSelection.annotationIndices(
            amounts: amounts, selectedIndex: selected,
            positions: positions ?? amounts.indices.map { CGFloat($0) * 100 + 20 },
            labelWidths: widths ?? amounts.map { _ in 32 }, plotWidth: plotWidth
        )
    }

    static func main() {
        require(labels([]).isEmpty, "empty data must not synthesize annotations")
        require(labels([7]) == [0], "one point is labeled exactly once")
        require(labels([0]) == [0], "a real zero remains valid known data")
        require(labels([3, 9, 1, 4]) == [1, 2, 3], "only last and extrema are labeled by default")
        require(labels([3, 9, 1, 4], selected: 0) == [0, 1, 2, 3], "selected point takes priority")
        require(labels([2, 2, 2, 2]) == [0, 3], "tied extrema choose a stable first point, not every point")
        require(labels([1, 2, 3, 4]) == [0, 3], "monotone last/max annotations deduplicate")
        require(labels([3, 9, 1, 4], selected: 99) == [1, 2, 3], "stale selection is ignored safely")

        let crampedPositions: [CGFloat?] = [10, 20, 30, 40]
        require(labels([3, 9, 1, 4], selected: 0, positions: crampedPositions, plotWidth: 50) == [0],
                "cramped labels never displace the selected point")
        require(labels([3, 9, 1, 4], positions: crampedPositions, plotWidth: 50) == [3],
                "without selection the last point wins collisions")
        require(labels([1], widths: [400], plotWidth: 50).isEmpty, "oversize labels are omitted")
        require(labels([1], plotWidth: 0).isEmpty, "zero-width plots do not label")
        require(labels([1, 2], positions: [nil, nil]).isEmpty, "missing plot coordinates are not fabricated")
        require(labels([1, 2], positions: [20]).isEmpty, "inconsistent geometry is rejected")

        require(AdaptiveChartSelection.nearestIndex(to: 90, positions: [10, 100, 200]) == 1,
                "pointer selection uses nearest real point")
        require(AdaptiveChartSelection.nearestIndex(to: 0, positions: [nil, 100, 200]) == 1,
                "selection skips unmapped points")
        require(AdaptiveChartSelection.nearestIndex(to: 20, positions: []) == nil,
                "empty chart has no selection")
        require(AdaptiveChartSelection.nearestIndex(to: .nan, positions: [20]) == nil,
                "invalid coordinates have no selection")
        require(AdaptiveChartSelection.labelCenter(0, width: 32, plotWidth: 100) == 16,
                "left-edge label remains inside plot")
        require(AdaptiveChartSelection.labelCenter(100, width: 32, plotWidth: 100) == 84,
                "right-edge label remains inside plot")

        let amounts = (0..<30).map { Decimal($0 % 7) }
        let positions: [CGFloat?] = amounts.indices.map { CGFloat($0) * 10 + 5 }
        let selectedLabels = labels(amounts, selected: 14, positions: positions, plotWidth: 300)
        require(selectedLabels.contains(14) && selectedLabels.count <= 4, "30-point trends remain sparse")
        let allowed: Set<Int> = [14, 29, 6, 0]
        require(selectedLabels.isSubset(of: allowed), "no ordinary point is annotated")
        require(AdaptiveChartSelection.nearestIndex(to: -500, positions: [10, 60]) == 0,
                "dragging before the plot selects the first known sample")
        require(AdaptiveChartSelection.nearestIndex(to: 500, positions: [10, 60]) == 1,
                "dragging after the plot selects the last known sample")
        print("PASS: AdaptiveLineChart selection and annotation checks (24 assertions)")
    }
}
