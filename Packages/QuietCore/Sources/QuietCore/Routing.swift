import Foundation

public enum HomeRoute: String, CaseIterable {
  case whatsapp, camera, oura, directions, conductor, remarkable, more, status
  case allApps = "all-apps"
  public static func parse(_ url: URL) -> HomeRoute? {
    guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
      c.scheme == "quiet", c.host == "open", c.user == nil, c.password == nil,
      c.port == nil, c.query == nil, c.fragment == nil,
      c.path.hasPrefix("/"), !c.path.dropFirst().contains("/"),
      !url.absoluteString.contains("%")
    else { return nil }
    return HomeRoute(rawValue: String(c.path.dropFirst()))
  }
}

// Non-launching compatibility metadata used to round-trip existing saved identities.
public enum AppCatalog {
  public static let home = ["whatsapp", "camera", "oura", "directions", "conductor", "remarkable"]
  public static let more = ["spotify", "soundcloud", "audible", "find-my", "surf-forecast", "windfinder"]
  public static let allow: [(String, String)] = [
    ("phone", "phone"), ("messages", "messages"), ("whatsapp", "whatsapp"), ("facetime", "facetime"),
    ("contacts", "contacts"), ("camera", "camera"), ("directions", "CoMaps"), ("clock", "clock"),
    ("calendar", "calendar"), ("reminders", "reminders"), ("notes", "notes"), ("calculator", "calculator"),
    ("voice-memos", "voice memos"), ("translate", "translate"), ("find-my", "find my"), ("wallet", "wallet"),
    ("health", "health"), ("oura", "oura"), ("childcare", "childcare"), ("strava", "strava"),
    ("music", "music"), ("spotify", "spotify"), ("podcasts", "podcasts"), ("settings", "settings"),
    ("conductor", "conductor"), ("pensieve", "pensieve"), ("remarkable", "reMarkable"),
    ("soundcloud", "soundcloud"), ("audible", "audible"), ("surf-forecast", "surf-forecast"),
    ("windfinder", "windfinder"), ("taxi", "taxi"), ("airline", "airline"), ("banking", "banking"),
    ("authenticator", "authenticator"),
  ]
}
