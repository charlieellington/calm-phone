import AppIntents
import QuietCore
import SwiftUI
import WidgetKit

struct QuietEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetSnapshot?
}
struct QuietTimelineProvider: TimelineProvider {
  func placeholder(in context: Context) -> QuietEntry { QuietEntry(date: Date(), snapshot: nil) }
  func getSnapshot(in context: Context, completion: @escaping (QuietEntry) -> Void) {
    completion(QuietEntry(date: Date(), snapshot: SharedContainer.snapshot()))
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<QuietEntry>) -> Void) {
    let now = Date()
    let snapshot = SharedContainer.snapshot()
    var entries = [QuietEntry(date: now, snapshot: snapshot)]
    if let end = snapshot?.leaseEnd, end > now { entries.append(QuietEntry(date: end, snapshot: snapshot)) }
    let midnight = CivilTime.calendar.dateInterval(of: .day, for: now)!.end
    entries.append(QuietEntry(date: midnight, snapshot: snapshot))
    completion(
      Timeline(entries: entries.sorted { $0.date < $1.date }, policy: .after(now.addingTimeInterval(3600))))
  }
}
struct LockNowIntent: AppIntent {
  static let title: LocalizedStringResource = "Lock now"
  static let description = IntentDescription("Restore Calm Phone app restrictions.")
  func perform() async throws -> some IntentResult {
    do {
      let database = try SharedContainer.database()
      try ApplePolicy.coordinator(database: database).lockNow()
    } catch {
      ApplePolicy.closeForRepair()
      throw error
    }
    WidgetCenter.shared.reloadAllTimelines()
    return .result()
  }
}

struct RetiredWidgetView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Widget removed").font(.headline)
      Link("Open Calm Phone", destination: URL(string: "quiet://open/status")!)
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .padding(24).foregroundStyle(QuietDesign.ink)
      .containerBackground(QuietDesign.paper, for: .widget)
  }
}
struct TodayWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "quiet.today", provider: QuietTimelineProvider()) { _ in RetiredWidgetView() }
      .configurationDisplayName("Calm Phone · retired date widget").description(
        "Open Calm Phone from its normal icon."
      )
      .supportedFamilies([.systemMedium]).contentMarginsDisabled()
  }
}
struct EssentialsWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "quiet.apps", provider: QuietTimelineProvider()) { _ in
      RetiredWidgetView()
    }
    .configurationDisplayName("Calm Phone · retired apps widget").description(
      "Open apps from their normal iPhone icons."
    )
    .supportedFamilies([.systemLarge]).contentMarginsDisabled()
  }
}
@main struct QuietWidgetBundle: WidgetBundle {
  var body: some Widget {
    TodayWidget()
    EssentialsWidget()
  }
}

#Preview(as: .systemLarge) { EssentialsWidget() } timeline: { QuietEntry(date: Date(), snapshot: nil) }
