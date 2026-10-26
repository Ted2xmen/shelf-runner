import AppKit
import Foundation
import ShelfBridgeCore
import UserNotifications

let agentBundleID = "dev.ted2xmen.shelf-bridge"

/// True when running as `ShelfBridge.app/Contents/MacOS/shelf-bridge` (not through a symlink):
/// only then does `UNUserNotificationCenter` work.
/// The string values of the Info.plist of the app bundle around the real binary. Found by path,
/// not `Bundle.main`: Homebrew's `shelf-bridge` is a symlink, and `Bundle.main` does not follow it.
let ownBundleInfo: [String: String]? = {
    let contents = URL(fileURLWithPath: selfExecutable()).deletingLastPathComponent().deletingLastPathComponent()
    guard let d = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any] else { return nil }
    return d.compactMapValues { $0 as? String }
}()

var runningInAgentBundle: Bool { ownBundleInfo?["CFBundleIdentifier"] == agentBundleID }

/// macOS notifications with Run / Ignore for approvals. Answers go through
/// `onAnswer`, which works the same whether the agent was running or macOS launched us for it.
final class AppNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let approveCategory = "APPROVE"
    static let runAction = "RUN"
    static let ignoreAction = "IGNORE"

    let center = UNUserNotificationCenter.current()
    var onAnswer: (_ id: String, _ action: String) -> Void

    init(onAnswer: @escaping (String, String) -> Void) {
        self.onAnswer = onAnswer
        super.init()
        center.delegate = self  // before the run loop, so a launch-time answer is delivered
        let run = UNNotificationAction(identifier: Self.runAction, title: "Run", options: [])
        let ignore = UNNotificationAction(identifier: Self.ignoreAction, title: "Ignore", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.approveCategory, actions: [run, ignore],
                                                                 intentIdentifiers: [], options: [])])
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { ok, err in
            if !ok { FileHandle.standardError.write(Data("[\(Clock.iso())] notifications not allowed: \(err.map { "\($0)" } ?? "off"); to approve: shelf-bridge approve <id>\n".utf8)) }
        }
    }

    func notify(id: String, title: String, body: String, kind: NoticeKind) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if kind == .approve { c.categoryIdentifier = Self.approveCategory }
        // One notification per job and kind; a newer one replaces the older.
        center.add(UNNotificationRequest(identifier: kind.identifier(job: id), content: c, trigger: nil))
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let ident = r.notification.request.identifier
        if ident.hasPrefix("approve:"), r.actionIdentifier == Self.runAction || r.actionIdentifier == Self.ignoreAction {
            onAnswer(String(ident.dropFirst("approve:".count)), r.actionIdentifier)
        } else if r.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Self.open(NoticeKind.job(fromIdentifier: ident))
        }
        done()
    }

    /// A click on the notification itself: the decision is `NoticeClick.decide`, this only asks
    /// macOS what is installed and opens it.
    static func open(_ job: String?) {
        let ws = NSWorkspace.shared
        let shelf = ws.urlForApplication(withBundleIdentifier: NoticeClick.shelfBundleID)
        switch NoticeClick.decide(job: job, deskInstalled: ws.urlForApplication(toOpen: NoticeClick.deskURL(job: job)) != nil,
                                  shelfInstalled: shelf != nil) {
        case .openDesk(let url): ws.open(url)
        case .openShelf: if let shelf { ws.openApplication(at: shelf, configuration: NSWorkspace.OpenConfiguration()) }
        case .nothing: break
        }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .list, .sound])
    }
}
