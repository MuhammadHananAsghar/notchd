// NotchMotion.swift
// The motion vocabulary, in one place so the whole surface moves like one
// thing. Springs throughout, tuned just under bouncy so there is a single soft
// settle rather than a wobble. Kept from Notchd.

import SwiftUI

/// Animations for the notch.
enum NotchMotion {
    /// Folding open and shut.
    static let unfold = Animation.spring(response: 0.42, dampingFraction: 0.78)
    /// Contents arriving after the shape has started opening.
    static let contents = Animation.spring(response: 0.36, dampingFraction: 0.82)
    /// Contents changing inside something already moving.
    static let crossfade = Animation.easeInOut(duration: 0.16)

    /// The resting dot breathing while an agent works. Slow, so it reads as
    /// alive rather than as an alert.
    static let breath = Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)
    /// The dots hopping once when a turn finishes: a quick spring with a
    /// little overshoot, the way a small thing nods.
    static let hop = Animation.interpolatingSpring(stiffness: 420, damping: 13)
    /// The peek tab coming out and going back. A touch bouncier than the
    /// unfold, since it is small and brief.
    static let peek = Animation.spring(response: 0.38, dampingFraction: 0.68)
    /// The tick drawing in on the peek.
    static let check = Animation.spring(response: 0.32, dampingFraction: 0.6)

    /// Each row trails the one before it, capped so a long list never drags.
    /// - Parameter index: The row's index.
    /// - Returns: The staggered animation.
    static func stagger(index: Int) -> Animation {
        contents.delay(min(Double(index) * 0.045, 0.18))
    }

    /// The animation, or none when the system asks for less movement.
    /// - Parameters:
    ///   - animation: The animation wanted.
    ///   - reduce: The accessibility setting.
    /// - Returns: The animation or nil.
    static func respectingReduceMotion(_ animation: Animation, _ reduce: Bool) -> Animation? {
        reduce ? nil : animation
    }
}
