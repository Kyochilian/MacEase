import Foundation

/// Something the machine did that playback has to answer for.
///
/// These are the Gate C conditions that no unit test can produce by driving
/// the app: the lid closing, headphones being unplugged, Wi-Fi dropping. They
/// are modelled as events behind a protocol so the *decisions* — what pauses,
/// what only reports — are testable even though the triggers are not.
package enum SystemPlaybackEvent: Equatable, Sendable {
  case willSleep
  case didWake
  /// The default output device disappeared: headphones unplugged, a USB
  /// interface removed, a Bluetooth speaker out of range. Audio has nowhere to
  /// go, and continuing would resume on the built-in speakers at whatever
  /// volume they happen to be set to.
  case audioOutputDeviceLost
  /// The default output device changed but the previous one still exists, so
  /// the user chose a different destination. Audio follows it; nothing pauses.
  case audioOutputDeviceChanged
  case networkReachabilityChanged(Bool)
}

/// The machine-state surface `PlaybackController` observes.
@MainActor
package protocol SystemEventObserving: AnyObject {
  var onEvent: (@MainActor (SystemPlaybackEvent) -> Void)? { get set }
  func start()
  func stop()
}
