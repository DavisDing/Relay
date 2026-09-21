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
