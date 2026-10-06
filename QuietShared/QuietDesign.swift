import Foundation
import SwiftUI

enum QuietDesign {
  static let paper = Color.black
  static let evening = Color.black
  static let ink = Color(white: 245 / 255)
  static let muted = Color(white: 173 / 255)
  static let surface = Color(white: 23 / 255)
  static let separator = Color(white: 56 / 255)
  static let sage = ink
  static let amber = ink
}

struct CalmPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.body.weight(.semibold))
      .frame(maxWidth: .infinity, minHeight: 56)
      .foregroundStyle(Color.black)
      .background(QuietDesign.ink.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35))
      .clipShape(RoundedRectangle(cornerRadius: 16))
  }
}

enum CalmTime {
  static func deadline(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = .current
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }
}
