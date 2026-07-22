import AppKit

extension NSColor {
    /// Parses `#RGB`, `#RRGGBB`, or `#RRGGBBAA` (with or without the leading
    /// `#`) as sRGB.
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.allSatisfy(\.isHexDigit) else { return nil }

        let expanded: String
        switch hex.count {
        case 3: expanded = hex.map { "\($0)\($0)" }.joined()
        case 6, 8: expanded = hex
        default: return nil
        }
        guard let value = UInt64(expanded, radix: 16) else { return nil }

        let hasAlpha = expanded.count == 8
        let shift = hasAlpha ? 8 : 0
        let r = CGFloat((value >> (16 + shift)) & 0xFF) / 255
        let g = CGFloat((value >> (8 + shift)) & 0xFF) / 255
        let b = CGFloat((value >> shift) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// sRGB components, which is what every developer-facing format wants.
    var srgbComponents: (r: Int, g: Int, b: Int, a: CGFloat)? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        return (
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded()),
            srgb.alphaComponent
        )
    }

    /// Uppercase `#RRGGBB`, or `#RRGGBBAA` when not fully opaque.
    var hexString: String {
        guard let c = srgbComponents else { return "#000000" }
        if c.a < 0.999 {
            return String(format: "#%02X%02X%02X%02X", c.r, c.g, c.b, Int((c.a * 255).rounded()))
        }
        return String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }

    /// True when white text reads better than black on this color.
    var prefersLightForeground: Bool {
        guard let srgb = usingColorSpace(.sRGB) else { return true }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
        return luminance < 0.45
    }

    /// The formats a developer actually retypes by hand.
    var developerFormats: [(label: String, value: String)] {
        guard let c = srgbComponents else { return [] }
        let hasAlpha = c.a < 0.999
        let alpha = String(format: "%.2f", c.a)
        let (h, s, l) = hslComponents

        var formats: [(String, String)] = [
            ("Hex", hexString),
            ("CSS rgb()", hasAlpha
                ? "rgb(\(c.r) \(c.g) \(c.b) / \(alpha))"
                : "rgb(\(c.r) \(c.g) \(c.b))"),
            ("CSS hsl()", hasAlpha
                ? "hsl(\(h) \(s)% \(l)% / \(alpha))"
                : "hsl(\(h) \(s)% \(l)%)"),
        ]

        let f = { (value: CGFloat) in String(format: "%.3f", value) }
        guard let srgb = usingColorSpace(.sRGB) else { return formats }
        formats.append(("SwiftUI Color", hasAlpha
            ? "Color(red: \(f(srgb.redComponent)), green: \(f(srgb.greenComponent)), blue: \(f(srgb.blueComponent)), opacity: \(alpha))"
            : "Color(red: \(f(srgb.redComponent)), green: \(f(srgb.greenComponent)), blue: \(f(srgb.blueComponent)))"))
        formats.append(("UIColor", "UIColor(red: \(f(srgb.redComponent)), green: \(f(srgb.greenComponent)), blue: \(f(srgb.blueComponent)), alpha: \(alpha))"))
        formats.append(("NSColor", "NSColor(srgbRed: \(f(srgb.redComponent)), green: \(f(srgb.greenComponent)), blue: \(f(srgb.blueComponent)), alpha: \(alpha))"))
        return formats
    }

    private var hslComponents: (h: Int, s: Int, l: Int) {
        guard let srgb = usingColorSpace(.sRGB) else { return (0, 0, 0) }
        let r = srgb.redComponent, g = srgb.greenComponent, b = srgb.blueComponent
        let maxValue = max(r, g, b), minValue = min(r, g, b)
        let delta = maxValue - minValue
        let lightness = (maxValue + minValue) / 2

        var hue: CGFloat = 0
        if delta > 0 {
            switch maxValue {
            case r: hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            case g: hue = 60 * (((b - r) / delta) + 2)
            default: hue = 60 * (((r - g) / delta) + 4)
            }
        }
        if hue < 0 { hue += 360 }
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        return (Int(hue.rounded()), Int((saturation * 100).rounded()), Int((lightness * 100).rounded()))
    }
}
