import Foundation
import QuietCore
import SwiftData
import SwiftUI

@Model final class UnlockInterval {
  @Attribute(.unique) var id: UUID
  var start: Date
  var plannedEnd: Date
  var earlyEnd: Date?
  var relockedAt: Date?
  /// Who unlocked by link; nil for the PIN. Optional, so existing stores migrate without a reset.
  var remoteName: String?
  init(lease: Lease) {
    id = lease.id
    start = lease.activatedAt!
    plannedEnd = lease.expiresAt
    earlyEnd = lease.endedAt
    relockedAt = lease.relockedAt
    remoteName = lease.remoteName
  }
  var lease: Lease {
    var lease = Lease(now: start, expiresAt: plannedEnd)
    lease.id = id
    lease.activatedAt = start
    lease.endedAt = earlyEnd
    lease.relockedAt = relockedAt
    lease.remoteName = remoteName
    lease.state = earlyEnd == nil ? .active : .ended
    return lease
  }
}

@MainActor enum HistoryProjection {
  static func configuration() throws -> ModelConfiguration {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let directory = support.appendingPathComponent("QuietHistory", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    return ModelConfiguration(
      "QuietHistory", schema: Schema([UnlockInterval.self]),
      url: directory.appendingPathComponent("history.store"), cloudKitDatabase: .none)
  }
  static func container() throws -> ModelContainer {
    try ModelContainer(for: UnlockInterval.self, configurations: configuration())
  }
  static func replay(_ state: ControlState, into context: ModelContext, now: Date) throws {
    let existing = try context.fetch(FetchDescriptor<UnlockInterval>())
    let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    for lease in state.leases where lease.activatedAt != nil {
      if let item = byID[lease.id] {
        item.earlyEnd = lease.endedAt
        item.relockedAt = lease.relockedAt
        item.remoteName = lease.remoteName
      } else {
        context.insert(UnlockInterval(lease: lease))
      }
    }
    let first = CivilTime.calendar.date(
      byAdding: .day, value: -29, to: CivilTime.calendar.startOfDay(for: now))!
    for item in try context.fetch(FetchDescriptor<UnlockInterval>())
    where (item.earlyEnd ?? item.plannedEnd) < first {
      context.delete(item)
    }
    try context.save()
  }
}

struct HistoryUnavailableView: View {
  @EnvironmentObject private var model: QuietModel
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text("History unavailable").font(.largeTitle.weight(.semibold))
      Text("Your history could not be read.").foregroundStyle(QuietDesign.muted)
      Button("Try again") { model.retryHistory() }.buttonStyle(CalmPrimaryButtonStyle())
    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(QuietDesign.paper)
  }
}

struct HistoryDestinationView: View {
  @EnvironmentObject private var model: QuietModel
  var body: some View {
    Group {
      if let container = model.historyContainer, model.historyError == nil {
        HistoryView(now: model.now).modelContainer(container)
      } else {
        HistoryUnavailableView()
      }
    }.navigationTitle("History")
  }
}

@MainActor final class HistorySelection: ObservableObject {
  @Published var offset = 0
  @Published var selected: Date?
  @Published var measure = 0
}

struct HistoryView: View {
  let now: Date
  @Query private var intervals: [UnlockInterval]
  @StateObject private var selection: HistorySelection
  @MainActor init(now: Date, selection: HistorySelection? = nil) {
    self.now = now
    _selection = StateObject(wrappedValue: selection ?? HistorySelection())
  }
  private var window: DailyHistoryWindow {
    DailyHistoryWindow(leases: intervals.map(\.lease), now: now, offset: selection.offset)
  }
  private var day: HistoryDay { window.days.first { $0.id == selection.selected } ?? window.days.last! }
  var body: some View {
    Group {
      if _intervals.fetchError != nil {
        HistoryUnavailableView()
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            range
            totals
            Picker("Graph measure", selection: $selection.measure) {
              Text("Time unlocked").tag(0)
              Text("Unlocks").tag(1)
            }.pickerStyle(.segmented)
            graph
            ViewThatFits(in: .horizontal) {
              HStack {
                Text(dateLabel(day.id, "EEE d MMM")).fontWeight(.semibold)
                Spacer()
                Text(summary(day))
              }
              VStack(alignment: .leading) {
                Text(dateLabel(day.id, "EEE d MMM")).fontWeight(.semibold)
                Text(summary(day))
              }
            }
            records
            Text("Time unlocked includes time with the screen off.\nDays use Brussels time.")
              .font(.footnote).foregroundStyle(QuietDesign.muted)
          }.padding(24)
        }.background(QuietDesign.paper)
      }
    }
  }
  private var range: some View {
    HStack {
      Button {
        selection.offset += 7
        selection.selected = nil
      } label: {
        Image(systemName: "chevron.left").frame(width: 44, height: 44)
      }
      .disabled(!window.canGoOlder).accessibilityLabel("Previous seven days")
      Spacer()
      Text("\(dateLabel(window.days.first!.id, "d MMM"))–\(dateLabel(window.days.last!.id, "d MMM"))")
        .font(.subheadline).foregroundStyle(QuietDesign.muted)
      Spacer()
      Button {
        selection.offset -= 7
        selection.selected = nil
      } label: {
        Image(systemName: "chevron.right").frame(width: 44, height: 44)
      }
      .disabled(!window.canGoNewer).accessibilityLabel("Next seven days")
    }
  }
  private var totals: some View {
    HStack(alignment: .top, spacing: 24) {
      VStack(alignment: .leading, spacing: 8) {
        Text("\(window.unlocks)").font(.largeTitle).monospacedDigit()
        Text("Unlocks").font(.footnote).foregroundStyle(QuietDesign.muted)
      }
      VStack(alignment: .leading, spacing: 8) {
        Text(DailyHistoryWindow.duration(window.seconds)).font(.largeTitle).monospacedDigit()
        Text("Time unlocked").font(.footnote).foregroundStyle(QuietDesign.muted)
      }
    }.accessibilityElement(children: .combine)
  }
  private var maximum: Double {
    if selection.measure == 0 { return max(30, ceil((window.days.map(\.seconds).max() ?? 0) / 1800) * 30) }
    return max(2, Double(window.days.map(\.unlocks).max() ?? 0))
  }
  private var graph: some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(window.days) { item in
        Button {
          selection.selected = item.id
        } label: {
          VStack(spacing: 8) {
            VStack {
              Spacer(minLength: 0)
              RoundedRectangle(cornerRadius: 4)
                .fill(item.id == day.id ? QuietDesign.ink : Color(white: 0.45))
                .frame(
                  height: 118 * (selection.measure == 0 ? item.seconds / 60 : Double(item.unlocks)) / maximum
                )
                .frame(maxWidth: 22)
            }.frame(height: 118).frame(maxWidth: .infinity)
              .overlay(alignment: .bottom) { Rectangle().fill(QuietDesign.separator).frame(height: 1) }
            Text(dateLabel(item.id, "EEEEE")).font(.caption)
            Text(dateLabel(item.id, "d")).font(.caption2)
          }.frame(maxWidth: .infinity).padding(.vertical, 6)
            .overlay(
              RoundedRectangle(cornerRadius: 5).stroke(item.id == day.id ? QuietDesign.muted : Color.clear))
        }.buttonStyle(.plain)
          .accessibilityLabel("\(dateLabel(item.id, "EEEE d MMMM")), \(summary(item))")
          .accessibilityAddTraits(item.id == day.id ? [.isSelected] : [])
          .accessibilityIdentifier("history-day-\(CivilTime.day(item.id))")
      }
      VStack {
        Text("\(Int(maximum))")
        if selection.measure == 0 { Text("min") }
        Spacer()
        Text("0")
      }
      .font(.system(size: 10)).foregroundStyle(QuietDesign.muted).frame(width: 19, height: 118)
      .accessibilityHidden(true)
    }
  }
  private var records: some View {
    VStack(alignment: .leading, spacing: 16) {
      if day.records.isEmpty {
        Text(intervals.isEmpty ? "No unlocks yet" : "No unlocks this day").foregroundStyle(QuietDesign.muted)
      }
      ForEach(day.records) { lease in
        let start = max(lease.activatedAt!, day.interval.start)
        let end = min(lease.endedAt ?? lease.expiresAt, lease.expiresAt, day.interval.end, now)
        VStack(alignment: .leading, spacing: 6) {
          Text("\(timeLabel(start))–\(timeLabel(end))").monospacedDigit()
          Text(
            "Everything · \(DailyHistoryWindow.duration(max(0, end.timeIntervalSince(start))))"
              + (lease.remoteName.map { " · \($0)" } ?? "")
          )
          .font(.footnote).foregroundStyle(QuietDesign.muted)
          if lease.activatedAt! < day.interval.start {
            Text("Continued access").font(.caption).foregroundStyle(QuietDesign.muted)
          }
          if let early = lease.endedAt, early < lease.expiresAt {
            Text("Ended early").font(.caption).foregroundStyle(QuietDesign.muted)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
        Divider().overlay(QuietDesign.separator)
      }
    }
  }
  private func summary(_ day: HistoryDay) -> String {
    "\(day.unlocks) \(day.unlocks == 1 ? "unlock" : "unlocks") · \(DailyHistoryWindow.duration(day.seconds))"
  }
  private func dateLabel(_ date: Date, _ template: String) -> String {
    let formatter = DateFormatter()
    formatter.calendar = CivilTime.calendar
    formatter.timeZone = CivilTime.calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter.string(from: date)
  }
  private func timeLabel(_ date: Date) -> String { dateLabel(date, "HHmm") }
}
