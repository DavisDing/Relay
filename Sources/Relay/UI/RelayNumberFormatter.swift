import Foundation

/// Centralized presentation formatting. Monetary values are rounded with
/// decimal `.plain` rounding (traditional 四舍五入) before display.
enum RelayNumberFormatter {
    static func money(_ amount: Decimal, currency: Currency) -> String {
        "\(currency.symbol)\(decimal(amount))"
    }

    static func decimal(_ amount: Decimal) -> String {
        var source = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 2, .plain)
        return formatter.string(from: rounded as NSDecimalNumber) ?? NSDecimalNumber(decimal: rounded).stringValue
    }

    /// Base-1000 display for home balances and credits, always retaining two decimals.
    static func compactDecimal(_ amount: Decimal) -> String {
        compactDecimal(amount, narrow: false)
    }

    /// Three significant digits fit the model table; full amounts stay in help/accessibility.
    static func modelMetric(_ amount: Decimal, currency: Currency? = nil) -> String {
        guard !amount.isNaN else { return "--" }
        return (currency?.symbol ?? "") + compactDecimal(amount, narrow: true)
    }

    private static func compactDecimal(_ amount: Decimal, narrow: Bool) -> String {
        guard !amount.isNaN else { return "—" }
        let units = ["", "K", "M", "B", "T", "P", "E"]
        var value = amount
        var unit = 0
        while abs(value) >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        var rounded = Decimal()
        let places = narrow ? (abs(value) >= 100 ? 0 : abs(value) >= 10 ? 1 : 2) : 2
        NSDecimalRound(&rounded, &value, places, .plain)
        if abs(rounded) >= 1000 && unit < units.count - 1 {
            rounded /= 1000
            unit += 1
        }
        if abs(rounded) >= 1000 {
            return (narrow ? narrowScientificFormatter : scientificFormatter).string(from: amount as NSDecimalNumber) ?? "—"
        }
        return ((narrow ? tokenFormatter : compactFormatter).string(from: rounded as NSDecimalNumber) ?? "—") + units[unit]
    }

    static func compactMoney(_ amount: Decimal, currency: Currency) -> String {
        guard !amount.isNaN else { return "—" }
        return currency.symbol + compactDecimal(amount)
    }

    private static let compactFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let scientificFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .scientific
        formatter.positiveFormat = "0.00E0"
        formatter.negativeFormat = "-0.00E0"
        return formatter
    }()

    private static let narrowScientificFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .scientific
        formatter.positiveFormat = "0.##E0"
        formatter.negativeFormat = "-0.##E0"
        return formatter
    }()

    /// Decimal units keep the narrow model table readable; full counts remain in the tooltip.
    static func tokens(_ count: Int64) -> String {
        guard count >= 0 else { return "--" }
        let units = ["", "K", "M", "B", "T", "P", "E"]
        var value = Decimal(count)
        var unit = 0
        while value >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        // Promote a rounded 1000K to 1M rather than widening the column.
        if rounded >= 1000 && unit < units.count - 1 {
            rounded /= 1000
            unit += 1
        }
        return (tokenFormatter.string(from: rounded as NSDecimalNumber) ?? "--") + units[unit]
    }

    private static let tokenFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    static func percent(_ ratio: Decimal) -> String {
        decimal(ratio * 100) + "%"
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        return formatter
    }()
}
