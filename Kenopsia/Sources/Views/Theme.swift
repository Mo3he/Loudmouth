import SwiftUI

// MARK: - Kenopsia design tokens
extension Color {
    /// Near-black primary background — adapts to light/dark mode
    static let kBackground = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
            : UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    })
    /// Elevated surface — adapts to light/dark mode
    static let kSurface = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.10, alpha: 1)
            : UIColor(white: 0.90, alpha: 1)
    })
    /// Cyan accent: #00D9E6 (default — overridden by user preference via kAccent env)
    static let kCyan = Color(red: 0.0, green: 0.85, blue: 0.90)
    /// Subtle border / separator — adapts to light/dark mode
    static let kBorder = Color.primary.opacity(0.10)
}

// MARK: - Accent color environment key
private struct AccentColorKey: EnvironmentKey {
    static let defaultValue: Color = .kCyan
}

extension EnvironmentValues {
    var kAccent: Color {
        get { self[AccentColorKey.self] }
        set { self[AccentColorKey.self] = newValue }
    }
}

// MARK: - Sidebar toggle environment key
private struct SidebarToggleKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var sidebarToggle: (() -> Void)? {
        get { self[SidebarToggleKey.self] }
        set { self[SidebarToggleKey.self] = newValue }
    }
}

// MARK: - Color hex utilities
extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 else { return nil }
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        self.init(.sRGB,
                  red:   Double((int >> 16) & 0xFF) / 255,
                  green: Double((int >>  8) & 0xFF) / 255,
                  blue:  Double( int        & 0xFF) / 255)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X",
                      Int((r * 255).rounded()),
                      Int((g * 255).rounded()),
                      Int((b * 255).rounded()))
    }
}
