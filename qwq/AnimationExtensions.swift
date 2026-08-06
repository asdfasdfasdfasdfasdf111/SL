import SwiftUI

extension Animation {
    static let insaneSpring = Animation.spring(response: 1.2, dampingFraction: 0.3, blendDuration: 0.5)
    static let explosiveSpring = Animation.spring(response: 0.7, dampingFraction: 0.5, blendDuration: 0.2)
    static let wildSpring = Animation.spring(response: 0.8, dampingFraction: 0.45, blendDuration: 0.25)
    static let bounceBack = Animation.interpolatingSpring(mass: 1.5, stiffness: 200, damping: 12, initialVelocity: 0)
    static let exaggeratedSpring = Animation.spring(response: 0.9, dampingFraction: 0.4, blendDuration: 0.35)
    static let punchySpring = Animation.spring(response: 0.6, dampingFraction: 0.5, blendDuration: 0.2)
}