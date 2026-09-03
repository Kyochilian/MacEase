import AppKit
import MacEaseAppCore
import NeteaseKit

/// The Dock asks the application delegate for a menu. The delegate owns no
/// playback fields; it rebuilds labels and enablement from the same live
/// router used by Now Playing and the app menu.
@MainActor
final class MacEaseAppDelegate: NSObject, NSApplicationDelegate {
  private static let terminationGrace: Duration = .seconds(5)

  private var router: SystemMediaRouter?
  private var refreshNotificationAuthorization: (@MainActor () async -> Void)?
  private var prepareForTermination: (@MainActor () async -> Void)?
  private var terminationIsPending = false

  func configure(
    router: SystemMediaRouter,
    refreshNotificationAuthorization: @escaping @MainActor () async -> Void,
    prepareForTermination: @escaping @MainActor () async -> Void
  ) {
    self.router = router
    self.refreshNotificationAuthorization = refreshNotificationAuthorization
    self.prepareForTermination = prepareForTermination
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    guard let refreshNotificationAuthorization else { return }
    Task { await refreshNotificationAuthorization() }
  }

  func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    guard let prepareForTermination else { return .terminateNow }
    guard !terminationIsPending else { return .terminateLater }
    terminationIsPending = true
    let timeout = Task { [weak self, weak sender] in
      try? await Task.sleep(for: Self.terminationGrace)
      guard !Task.isCancelled, let self, let sender else { return }
      self.finishTermination(sender)
    }
    Task { [weak self, weak sender] in
      await prepareForTermination()
      timeout.cancel()
      guard let self, let sender else { return }
      self.finishTermination(sender)
    }
    return .terminateLater
  }

  /// Feedback gets a short grace period, but a dead connection must never
  /// leave the application stuck in "terminating". Both completion paths use
  /// this gate, so only the first one replies to AppKit.
  private func finishTermination(_ sender: NSApplication) {
    guard terminationIsPending else { return }
    terminationIsPending = false
    sender.reply(toApplicationShouldTerminate: true)
  }

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    guard let router else { return nil }
    let menu = NSMenu(title: "Playback")
    menu.autoenablesItems = false
    let snapshot = router.snapshot()
    add(
      snapshot.state == .playing ? "Pause" : "Play",
      action: #selector(togglePlayback),
      command: .togglePlayback,
      to: menu
    )
    add("Previous", action: #selector(previous), command: .previous, to: menu)
    add("Next", action: #selector(next), command: .next, to: menu)
    menu.addItem(.separator())
    let mode = router.playbackMode
    let shuffleTarget: PlaybackMode = mode == .shuffle ? .sequential : .shuffle
    let shuffle = add(
      "Shuffle",
      action: #selector(toggleShuffle),
      command: .setMode(shuffleTarget),
      to: menu
    )
    shuffle.state = mode == .shuffle ? .on : .off

    let repeatItem = NSMenuItem(title: "Repeat", action: nil, keyEquivalent: "")
    let repeatMenu = NSMenu(title: "Repeat")
    repeatMenu.autoenablesItems = false
    for choice in [PlaybackMode.sequential, .repeatAll, .repeatOne] {
      let item = add(
        choice.dockTitle,
        action: #selector(setRepeatMode(_:)),
        command: .setMode(choice),
        to: repeatMenu
      )
      item.representedObject = choice.rawValue
      item.state = mode == choice ? .on : .off
    }
    repeatItem.submenu = repeatMenu
    repeatItem.isEnabled = router.canPerform(.setMode(.sequential))
    menu.addItem(repeatItem)
    menu.addItem(.separator())
    let likeTitle = switch snapshot.liked {
    case .liked: "Unlike"
    case .notLiked: "Like"
    case .unknown: "Like/Unlike"
    }
    add(
      likeTitle,
      action: #selector(toggleLiked),
      command: .toggleLiked,
      to: menu
    )
    return menu
  }

  @discardableResult
  private func add(
    _ title: String,
    action: Selector,
    command: AppPlaybackCommand,
    to menu: NSMenu
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = router?.canPerform(command) == true
    menu.addItem(item)
    return item
  }

  @objc private func togglePlayback() { _ = router?.perform(.togglePlayback) }
  @objc private func previous() { _ = router?.perform(AppPlaybackCommand.previous) }
  @objc private func next() { _ = router?.perform(AppPlaybackCommand.next) }
  @objc private func toggleLiked() { _ = router?.perform(.toggleLiked) }
  @objc private func toggleShuffle() {
    guard let router else { return }
    let mode: PlaybackMode = router.playbackMode == .shuffle ? .sequential : .shuffle
    _ = router.perform(.setMode(mode))
  }

  @objc private func setRepeatMode(_ sender: NSMenuItem) {
    guard let rawValue = sender.representedObject as? String,
      let mode = PlaybackMode(rawValue: rawValue)
    else { return }
    _ = router?.perform(.setMode(mode))
  }
}

private extension PlaybackMode {
  var dockTitle: String {
    switch self {
    case .sequential: "Off"
    case .repeatAll: "Repeat All"
    case .repeatOne: "Repeat One"
    case .shuffle: "Shuffle"
    }
  }
}
