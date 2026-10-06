import DeviceActivity
import QuietCore

final class DeviceActivityMonitorExtension: DeviceActivityMonitor {
  private func reconcile(
    _ activity: DeviceActivityName, event: DeviceActivityEvent.Name? = nil, ended: Bool = false
  ) {
    do {
      try ApplePolicy.handleCallback(
        activity: activity.rawValue, event: event?.rawValue, didEnd: ended)
    } catch {
      if let database = try? SharedContainer.database() { try? database.update { $0.monitorFailed = true } }
    }
  }
  override func intervalDidStart(for activity: DeviceActivityName) { reconcile(activity) }
  override func intervalDidEnd(for activity: DeviceActivityName) { reconcile(activity, ended: true) }
  override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
    reconcile(activity, event: event)
  }
}
