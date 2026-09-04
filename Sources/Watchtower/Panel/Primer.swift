import SwiftUI
import AppKit

/// GitHub's Primer design system, ported to AppKit/SwiftUI.
///
/// Primer ships as CSS custom properties with a light and a dark value per token. The port
/// keeps that shape: every colour here is an `NSColor` with a dynamic provider, so a single
/// token resolves correctly in both schemes. That matters more than usual in this app —
/// `--preview` and `--render` put a light pane and a dark pane in the same window, each
/// pinned to its own `NSAppearance`, and `@Environment(\.colorScheme)` cannot serve both.
///
/// Values are Primer's own (primer/primitives), not eyeballed approximations. The handful of
/// tokens Primer defines with alpha (`neutral.muted`, the *.subtle backgrounds in dark mode)
/// are flattened against their canvas, because these sit on a vibrant menu-bar popover where
/// a translucent fill would composite against the desktop instead.
enum Primer {

    // MARK: - Colour tokens

    /// Page and box backgrounds.
    static let canvasDefault = dynamic(0xFFFFFF, 0x0D1117)
    static let canvasSubtle  = dynamic(0xF6F8FA, 0x151B23)
    static let canvasInset   = dynamic(0xEEF1F4, 0x010409)

    /// Borders. Primer draws every box, label and button with a 1px `border.default`.
    static let borderDefault = dynamic(0xD1D9E0, 0x3D444D)
    static let borderMuted   = dynamic(0xE1E7ED, 0x2A2F37)

    /// Text.
    static let fgDefault = dynamic(0x1F2328, 0xF0F6FC)
    static let fgMuted   = dynamic(0x59636E, 0x9198A1)
    static let fgSubtle  = dynamic(0x818B98, 0x656C76)
    static let fgOnEmphasis = dynamic(0xFFFFFF, 0xFFFFFF)

    /// Roles. `fg` is for text and icons, `emphasis` for filled surfaces, `subtle` for the
    /// tinted background behind a flash/callout.
    static let accentFg       = dynamic(0x0969DA, 0x4493F8)
    static let accentEmphasis = dynamic(0x0969DA, 0x1F6FEB)
    static let accentSubtle   = dynamic(0xDDF4FF, 0x121D2F)

    static let successFg       = dynamic(0x1A7F37, 0x3FB950)
    static let successEmphasis = dynamic(0x1F883D, 0x238636)
    static let successSubtle   = dynamic(0xDAFBE1, 0x0F2A18)

    static let attentionFg       = dynamic(0x9A6700, 0xD29922)
    static let attentionEmphasis = dynamic(0xBF8700, 0x9E6A03)
    static let attentionSubtle   = dynamic(0xFFF8C5, 0x272115)

    static let dangerFg       = dynamic(0xD1242F, 0xF85149)
    static let dangerEmphasis = dynamic(0xCF222E, 0xDA3633)
    static let dangerSubtle   = dynamic(0xFFEBE9, 0x2A1416)

    static let neutralEmphasis = dynamic(0x6E7781, 0x6E7681)
    static let neutralMuted    = dynamic(0xEAEEF2, 0x22282F)

    // MARK: - Type scale
    //
    // Primer's web scale is 12 / 14 / 16 / 20. A menu-bar popover is denser than a page, so
    // each step drops by two points; the ratios, weights and the mono/proportional split are
    // Primer's. `.monospaced` maps to SF Mono, which is what `-apple-system` mono resolves to
    // on macOS anyway.

    static func text(_ size: CGFloat = 12, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat = 11, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let title    = text(14, .semibold)   // page title
    static let subhead  = text(12, .semibold)   // box header
    static let body     = text(12)
    static let small    = text(11)
    static let caption  = text(10)

    // MARK: - Geometry

    /// Primer's `--borderRadius-medium`. Boxes, buttons and inputs all share it.
    static let radius: CGFloat = 6
    /// `--borderRadius-full`, for Labels and Counters.
    static let radiusFull: CGFloat = 999
    static let borderWidth: CGFloat = 1
    /// `--base-size-8/12/16`, scaled for the popover.
    static let padTight: CGFloat = 6
    static let pad: CGFloat = 10
    static let gap: CGFloat = 8

    // MARK: - Plumbing

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green:   CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue:    CGFloat(rgb & 0xFF) / 255,
                  alpha:   1)
    }
}

// MARK: - Role

/// The role a piece of UI carries, in Primer's vocabulary. One value selects a matching
/// foreground, emphasis and subtle background, so a caller never hand-picks three colours.
enum PrimerRole {
    case accent, success, attention, danger, neutral

    var fg: Color {
        switch self {
        case .accent:    return Primer.accentFg
        case .success:   return Primer.successFg
        case .attention: return Primer.attentionFg
        case .danger:    return Primer.dangerFg
        case .neutral:   return Primer.fgMuted
        }
    }

    var emphasis: Color {
        switch self {
        case .accent:    return Primer.accentEmphasis
        case .success:   return Primer.successEmphasis
        case .attention: return Primer.attentionEmphasis
        case .danger:    return Primer.dangerEmphasis
        case .neutral:   return Primer.neutralEmphasis
        }
    }

    var subtle: Color {
        switch self {
        case .accent:    return Primer.accentSubtle
        case .success:   return Primer.successSubtle
        case .attention: return Primer.attentionSubtle
        case .danger:    return Primer.dangerSubtle
        case .neutral:   return Primer.neutralMuted
        }
    }

    var border: Color {
        self == .neutral ? Primer.borderDefault : fg.opacity(0.4)
    }
}

// MARK: - Box

/// Primer's `Box` with a header: a 1px-bordered, 6px-radius surface whose header sits on
/// `canvas.subtle` above a divider. Every section of the panel is one of these, which is what
/// makes the layout read as a GitHub page rather than a stack of loose rows.
struct PrimerBox<Content: View>: View {
    let title: String
    var icon: String?
    var trailing: String?
    var accessory: AnyView?
    @ViewBuilder var content: () -> Content

    init(_ title: String,
         icon: String? = nil,
         trailing: String? = nil,
         accessory: AnyView? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.trailing = trailing
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundStyle(Primer.fgMuted)
                }
                Text(title)
                    .font(Primer.subhead)
                    .foregroundStyle(Primer.fgDefault)
                Spacer(minLength: 6)
                if let accessory {
                    accessory
                } else if let trailing {
                    Text(trailing)
                        .font(Primer.caption)
                        .monospacedDigit()
                        .foregroundStyle(Primer.fgMuted)
                }
            }
            .padding(.horizontal, Primer.pad)
            .padding(.vertical, Primer.padTight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Primer.canvasSubtle)

            PrimerRule()

            VStack(alignment: .leading, spacing: Primer.padTight) {
                content()
            }
            .padding(Primer.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Primer.canvasDefault)
        }
        .clipShape(RoundedRectangle(cornerRadius: Primer.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Primer.radius, style: .continuous)
                .strokeBorder(Primer.borderDefault, lineWidth: Primer.borderWidth)
        )
    }
}

/// A hairline in `border.default`. SwiftUI's `Divider` picks up the system separator colour,
/// which is not Primer's and does not match the box borders it has to meet.
struct PrimerRule: View {
    var body: some View {
        Rectangle()
            .fill(Primer.borderDefault)
            .frame(height: Primer.borderWidth)
    }
}

// MARK: - Label

/// Primer's `Label`: a pill with a 1px border in the role colour and no fill, or a filled
/// variant for states that need to shout. Used for alarm state and overall health.
struct PrimerLabel: View {
    let text: String
    var role: PrimerRole = .neutral
    var filled: Bool = false
    var icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(Primer.text(10, .medium))
        }
        .foregroundStyle(filled ? Primer.fgOnEmphasis : role.fg)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(filled ? role.emphasis : Color.clear)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(filled ? Color.clear : role.border, lineWidth: Primer.borderWidth)
        )
        .fixedSize()
    }
}

/// Primer's `Counter`: a filled neutral pill for a number sitting next to a heading.
struct PrimerCounter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Primer.mono(10, .medium))
            .foregroundStyle(Primer.fgDefault)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule(style: .continuous).fill(Primer.neutralMuted))
            .fixedSize()
    }
}

// MARK: - Buttons

/// Primer's default `btn`: `canvas.subtle` fill, `border.default` outline, 6px radius,
/// darkening to `canvas.inset` while pressed.
struct PrimerButtonStyle: ButtonStyle {
    var role: PrimerRole = .neutral
    var primary: Bool = false

    @Environment(\.isEnabled) private var isEnabled

    // Spelled out rather than `Configuration`: this module has its own top-level
    // `Configuration` (the app's settings), which shadows the protocol's typealias and makes
    // the conformance fail to resolve.
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(Primer.text(11, .medium))
            .foregroundStyle(primary ? Primer.fgOnEmphasis
                                     : (role == .neutral ? Primer.fgDefault : role.fg))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Primer.radius, style: .continuous)
                    .fill(primary ? role.emphasis
                                  : (configuration.isPressed ? Primer.canvasInset : Primer.canvasSubtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Primer.radius, style: .continuous)
                    .strokeBorder(primary ? Color.clear : Primer.borderDefault,
                                  lineWidth: Primer.borderWidth)
            )
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: Primer.radius, style: .continuous))
    }
}

/// Primer's `btn-invisible`: no chrome until pressed. For the icon-only refresh control and
/// for anything that reads as a link.
struct PrimerInvisibleButtonStyle: ButtonStyle {
    var role: PrimerRole = .accent

    @Environment(\.isEnabled) private var isEnabled

    // Spelled out rather than `Configuration`: this module has its own top-level
    // `Configuration` (the app's settings), which shadows the protocol's typealias and makes
    // the conformance fail to resolve.
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(Primer.text(11, .medium))
            .foregroundStyle(role.fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Primer.radius, style: .continuous)
                    .fill(configuration.isPressed ? Primer.neutralMuted : Color.clear)
            )
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: Primer.radius, style: .continuous))
    }
}

// MARK: - Flash

/// Primer's `flash`: a tinted, bordered callout. Every failure and every caveat in the panel
/// is one of these, so a degraded reading is impossible to mistake for a normal one.
struct PrimerFlash<Content: View>: View {
    var role: PrimerRole = .attention
    var icon: String = "exclamationmark.triangle.fill"
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(role.fg)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Primer.radius, style: .continuous)
                .fill(role.subtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Primer.radius, style: .continuous)
                .strokeBorder(role.border, lineWidth: Primer.borderWidth)
        )
    }
}

// MARK: - Rows

/// A `key → value` row in a box body, matching the label/value pairs GitHub uses down the
/// side of a repository page.
struct PrimerRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(Primer.small)
                .foregroundStyle(Primer.fgMuted)
                .lineLimit(1)
            Spacer(minLength: 8)
            value()
        }
    }
}
