import AppKit

/// The wishlist target price editor that replaces the "Target price" pill in place: Return saves, Escape or clicking
/// away puts the pill back. Empty removes the target; a number is a price; "30%" is 30% off the usual price.
final class TargetField: NSTextField {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        if movement == NSTextMovement.return.rawValue || movement == NSTextMovement.tab.rawValue {
            onCommit?(stringValue)
        } else {
            onCancel?()
        }
    }
}

/// A typed target: "9.99", "4 000 Ft" or a percent off `base` ("30%" or "-30%"). nil when it can't be read.
func parseTargetInput(_ raw: String, _ code: String, base: Double?) -> Double? {
    guard raw.contains("%") else { return parseTargetPrice(raw, code) }
    guard let base, base > 0, let percent = parseTargetPrice(raw.replacingOccurrences(of: "%", with: ""), "USD"),
          percent > 0, percent < 100 else { return nil }
    let places = ShopMoney.minorUnits(code)
    let factor = pow(10.0, Double(places))
    return ((base * (1 - percent / 100)) * factor).rounded() / factor
}
