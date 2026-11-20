//
//  TermTheme.swift
//
//  A 16-colour ANSI palette and a fixed character cell.
//
//  The intent is a real terminal, not a chat app with a monospace font. That
//  means: a fixed grid, square corners, no shadows, no blur, no spring
//  animations, no gradients. The only motion in the app is a blinking block
//  cursor.
//
//  Menlo ships with iOS and is metrically stable back to iOS 7, so it needs no
//  bundled font file. A bundled font would add to the app size for no gain.
//

import UIKit

public enum TermColor {
    case black, red, green, yellow, blue, magenta, cyan, white
    case brightBlack, brightRed, brightGreen, brightYellow
    case brightBlue, brightMagenta, brightCyan, brightWhite

    /// A restrained, low-contrast-on-black palette. Values are close to the
    /// classic xterm set, pulled slightly toward lower saturation so long
    /// reading sessions on an OLED-free 2015 display stay comfortable.
    public var uiColor: UIColor {
        switch self {
        case .black:         return UIColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1)
        case .red:           return UIColor(red: 0.80, green: 0.31, blue: 0.31, alpha: 1)
        case .green:         return UIColor(red: 0.42, green: 0.69, blue: 0.40, alpha: 1)
        case .yellow:        return UIColor(red: 0.80, green: 0.66, blue: 0.35, alpha: 1)
        case .blue:          return UIColor(red: 0.38, green: 0.57, blue: 0.78, alpha: 1)
        case .magenta:       return UIColor(red: 0.69, green: 0.46, blue: 0.73, alpha: 1)
        case .cyan:          return UIColor(red: 0.36, green: 0.68, blue: 0.69, alpha: 1)
        case .white:         return UIColor(red: 0.78, green: 0.78, blue: 0.76, alpha: 1)
        case .brightBlack:   return UIColor(red: 0.36, green: 0.38, blue: 0.40, alpha: 1)
        case .brightRed:     return UIColor(red: 0.90, green: 0.43, blue: 0.43, alpha: 1)
        case .brightGreen:   return UIColor(red: 0.55, green: 0.82, blue: 0.51, alpha: 1)
        case .brightYellow:  return UIColor(red: 0.92, green: 0.80, blue: 0.47, alpha: 1)
        case .brightBlue:    return UIColor(red: 0.51, green: 0.70, blue: 0.90, alpha: 1)
        case .brightMagenta: return UIColor(red: 0.82, green: 0.59, blue: 0.86, alpha: 1)
        case .brightCyan:    return UIColor(red: 0.49, green: 0.81, blue: 0.82, alpha: 1)
        case .brightWhite:   return UIColor(red: 0.93, green: 0.93, blue: 0.91, alpha: 1)
        }
    }
}

public struct TermTheme {

    public static let background = TermColor.black.uiColor
    public static let foreground = TermColor.white.uiColor

    /// Base size. 13pt on a 4-inch screen gives about 44 columns, which is
    /// enough for readable DM text without wrapping every line.
    public static let fontSize: CGFloat = 13.0

    public static let font = UIFont(name: "Menlo-Regular", size: fontSize)
        ?? UIFont(name: "Courier", size: fontSize)!

    public static let boldFont = UIFont(name: "Menlo-Bold", size: fontSize)
        ?? UIFont(name: "Courier-Bold", size: fontSize)!

    /// Advance width of one cell. Menlo is monospaced, so any glyph will do.
    public static let cellWidth: CGFloat = {
        let s = "M" as NSString
        return s.size(withAttributes: [.font: font]).width
    }()

    /// Row height. Slightly loose for readability on a small screen.
    public static let cellHeight: CGFloat = ceil(font.lineHeight * 1.15)

    /// Colour roles, so the views do not hard-code palette entries.
    public static let dim = TermColor.brightBlack
    public static let accent = TermColor.cyan
    public static let selfAuthor = TermColor.green
    public static let otherAuthor = TermColor.brightBlue
    public static let unread = TermColor.brightYellow
    public static let online = TermColor.green
    public static let offline = TermColor.brightBlack
    public static let warning = TermColor.brightRed
    public static let attachment = TermColor.magenta
    public static let prompt = TermColor.brightGreen

    /// Columns that fit a given width.
    public static func columns(for width: CGFloat) -> Int {
        return max(20, Int(floor(width / cellWidth)))
    }
}
