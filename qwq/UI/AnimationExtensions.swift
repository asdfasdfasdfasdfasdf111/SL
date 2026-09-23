import SwiftUI

extension Animation {
    static let explosiveSpring = Animation.spring(response: 0.7, dampingFraction: 0.5, blendDuration: 0.2)
    static let exaggeratedSpring = Animation.spring(response: 0.9, dampingFraction: 0.4, blendDuration: 0.35)
    static let punchySpring = Animation.spring(response: 0.6, dampingFraction: 0.5, blendDuration: 0.2)
}