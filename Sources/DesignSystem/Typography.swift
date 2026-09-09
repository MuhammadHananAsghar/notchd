// Typography.swift
// The type scale. System fonts throughout: a title for window and section
// headers, body and caption for rows, and a monospaced face for paths,
// commands, and JSON, which are most of what Notchd shows.

import SwiftUI

/// Notchd's type tokens.
enum Typography {
    /// Window and inspector titles.
    static let title = Font.system(size: 17, weight: .semibold)
    /// Section headers inside a panel.
    static let heading = Font.system(size: 13, weight: .semibold)
    /// Ordinary row text.
    static let body = Font.system(size: 13)
    /// Secondary detail under a row.
    static let caption = Font.system(size: 11)
    /// Paths, commands, identifiers.
    static let mono = Font.system(size: 12, design: .monospaced)
    /// Configuration snippets shown before they are written.
    static let code = Font.system(size: 11.5, design: .monospaced)
}
