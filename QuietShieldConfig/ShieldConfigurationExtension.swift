import ManagedSettings
import ManagedSettingsUI
import QuietCore
import UIKit

final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
  private func configuration(application: Application? = nil) -> ShieldConfiguration {
    var title = "Blocked"
    let subtitle = "Open Calm Phone to unlock."
    if let token = application?.token, let db = try? SharedContainer.database(),
      let state = try? db.load(), let policy = state.policy
    {
      let rule = policy.limits.first { rule in
        guard let data = Data(base64Encoded: rule.app.token),
          let saved = try? JSONDecoder().decode(ApplicationToken.self, from: data)
        else { return false }
        return saved == token
      }
      if let rule, state.exhaustedDay == CivilTime.day(Date()), state.exhausted.contains(rule.id) {
        title = "Daily limit reached"

      }
    }
    let ink = UIColor(white: 245 / 255, alpha: 1)
    return ShieldConfiguration(
      backgroundBlurStyle: .none, backgroundColor: .black,
      icon: nil, title: .init(text: title, color: ink),
      subtitle: .init(text: subtitle, color: UIColor(white: 173 / 255, alpha: 1)),
      primaryButtonLabel: .init(text: "Close", color: .black),
      primaryButtonBackgroundColor: ink)

  }
  override func configuration(shielding application: Application) -> ShieldConfiguration {
    configuration(application: application)
  }
  override func configuration(shielding application: Application, in category: ActivityCategory)
    -> ShieldConfiguration
  { configuration(application: application) }
  override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration { configuration() }
  override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory)
    -> ShieldConfiguration
  { configuration() }
}
