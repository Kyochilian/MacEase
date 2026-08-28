import AppKit
import CoreAudio
import Foundation
import Network

/// The real machine-state observer: AppKit for sleep and wake, CoreAudio for
/// the default output device, and `NWPathMonitor` for reachability.
///
/// It makes one judgement of its own, and only one: whether a default-output
/// change was a *loss* or a *switch*. That needs the device list from before
/// the change, which only something holding the listener can know, and getting
/// it wrong is the difference between pausing when a user picks a new speaker
/// and playing out loud when their headphones come off.
@MainActor
package final class MacSystemEventObserver: SystemEventObserving {
  package var onEvent: (@MainActor (SystemPlaybackEvent) -> Void)?

  private var workspaceObservers: [NSObjectProtocol] = []
  private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
  private var pathMonitor: NWPathMonitor?
  private var isRunning = false
  /// The output device in effect at the last check, and every device present
  /// at that moment. Both are needed: a change is a loss only when the device
  /// that was in use is no longer in the list.
  private var currentOutputDevice: AudioDeviceID?
  private var knownDeviceIDs: Set<AudioDeviceID> = []
  /// Reachability is reported only when it changes. `NWPathMonitor` delivers
  /// the current path immediately on start and then on every update, so
  /// without this the app would report "network available" at launch as if
  /// something had just happened.
  private var lastReachability: Bool?

  private static var defaultOutputDeviceAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )

  private static var devicesAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )

  package init() {}

  deinit {
    // Teardown touches MainActor state, so it cannot run here. `stop()` is the
    // supported path; the composition root holds one instance for the process
    // lifetime, so this exists for tests rather than for normal running.
  }

  package func start() {
    guard !isRunning else { return }
    isRunning = true
    currentOutputDevice = Self.defaultOutputDevice()
    knownDeviceIDs = Self.allDeviceIDs()
    observeSleepAndWake()
    observeAudioDevices()
    observeReachability()
  }

  package func stop() {
    guard isRunning else { return }
    isRunning = false
    for observer in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    workspaceObservers = []
    if let deviceListenerBlock {
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &Self.defaultOutputDeviceAddress,
        .main,
        deviceListenerBlock
      )
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &Self.devicesAddress,
        .main,
        deviceListenerBlock
      )
    }
    deviceListenerBlock = nil
    pathMonitor?.cancel()
    pathMonitor = nil
    lastReachability = nil
  }

  private func observeSleepAndWake() {
    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers = [
      center.addObserver(
        forName: NSWorkspace.willSleepNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.onEvent?(.willSleep) }
      },
      center.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.onEvent?(.didWake) }
      },
    ]
  }

  private func observeAudioDevices() {
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.handleAudioDeviceChange()
      }
    }
    deviceListenerBlock = block
    // Both properties are watched through one block. The default-device
    // property alone misses the case where the machine has no other output and
    // macOS leaves the stale id in place; the device-list property alone
    // cannot tell a switch from a loss.
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &Self.defaultOutputDeviceAddress,
      .main,
      block
    )
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &Self.devicesAddress,
      .main,
      block
    )
  }

  private func handleAudioDeviceChange() {
    let devices = Self.allDeviceIDs()
    let newDefault = Self.defaultOutputDevice()
    let previous = currentOutputDevice
    let previousKnown = knownDeviceIDs
    currentOutputDevice = newDefault
    knownDeviceIDs = devices

    guard let previous else { return }
    // A device the system had and no longer has, which was the one in use.
    if previousKnown.contains(previous), !devices.contains(previous) {
      onEvent?(.audioOutputDeviceLost)
      return
    }
    guard newDefault != previous else { return }
    onEvent?(.audioOutputDeviceChanged)
  }

  private func observeReachability() {
    let monitor = NWPathMonitor()
    pathMonitor = monitor
    monitor.pathUpdateHandler = { [weak self] path in
      let reachable = path.status == .satisfied
      Task { @MainActor [weak self] in
        guard let self, self.lastReachability != reachable else { return }
        self.lastReachability = reachable
        self.onEvent?(.networkReachabilityChanged(reachable))
      }
    }
    monitor.start(queue: DispatchQueue(label: "com.macease.reachability"))
  }

  /// Zero means "the system has no default output". It is returned as nil so
  /// no caller has to know that a device id of zero is not a device.
  private static func defaultOutputDevice() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &defaultOutputDeviceAddress,
      0,
      nil,
      &size,
      &deviceID
    )
    guard status == noErr, deviceID != 0 else { return nil }
    return deviceID
  }

  private static func allDeviceIDs() -> Set<AudioDeviceID> {
    var size = UInt32(0)
    var status = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &devicesAddress,
      0,
      nil,
      &size
    )
    let stride = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard status == noErr, size >= stride else { return [] }

    var ids = [AudioDeviceID](repeating: 0, count: Int(size / stride))
    status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &devicesAddress,
      0,
      nil,
      &size,
      &ids
    )
    guard status == noErr else { return [] }
    return Set(ids.prefix(Int(size / stride)))
  }
}
