// NotchdMain.swift
// The SwiftUI entry point. The app is a menu bar item plus AppKit windows the
// delegate puts up, so the only scene here is an empty Settings scene that
// exists because `App` requires one.

import SwiftUI

/// The application.
@main
struct NotchdMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
