import Foundation
import QuietCore
import SwiftData

@Model final class UnlockInterval {
  @Attribute(.unique) var id: UUID
  var start: Date
  var plannedEnd: Date
  var earlyEnd: Date?
  var relockedAt: Date?
  init(lease: Lease) {
    id = lease.id
    start = lease.activatedAt!
    plannedEnd = lease.expiresAt
    earlyEnd = lease.endedAt
    relockedAt = lease.relockedAt
  }
  var lease: Lease {
    var lease = Lease(now: start, expiresAt: plannedEnd)
    lease.id = id
    lease.activatedAt = start
    lease.endedAt = earlyEnd
    lease.relockedAt = relockedAt
    lease.state = earlyEnd == nil ? .active : .ended
    return lease
  }
}
