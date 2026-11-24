import AVKit
import CoreImage
import Flutter
import os
import UIKit

/// Picture-in-Picture for the video texture rendered by media_kit (mpv).
///
/// mpv renders into `CVPixelBuffer`s owned by a `FlutterTexture` that is
/// private to media_kit_video, so the engine's texture registry is hooked to
/// map texture ids to textures and to get notified of new frames. Frames of the
/// tracked texture are copied and fed to an `AVSampleBufferDisplayLayer`, which
/// is used as the PiP content source (iOS 15+).
///
/// Threading: `PipPlugin`, `PipSession` and `TextureTracker` are main thread
/// only. `FramePipeline` owns everything that touches frames and confines it
/// to its serial queue; the two only exchange messages.
final class PipPlugin: NSObject, FlutterPlugin {
  private static let channelName = "com.example.piliplus/pip"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = PipPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    TextureTracker.install(on: registrar.textures())
  }

  private let channel: FlutterMethodChannel
  private var _session: AnyObject?

  @available(iOS 15.0, *)
  private var session: PipSession? {
    get { _session as? PipSession }
    set { _session = newValue }
  }

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    TextureTracker.onFrameAvailable = { [weak self] textureId in
      guard #available(iOS 15.0, *), let session = self?.session,
        session.textureId == textureId
      else { return }
      session.frameAvailable()
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard #available(iOS 15.0, *) else {
      result(call.method == "isAvailable" ? false : nil)
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "isAvailable":
      result(AVPictureInPictureController.isPictureInPictureSupported())
    case "enter":
      guard let textureId = (args["textureId"] as? NSNumber)?.int64Value else {
        result(FlutterError(code: "ARGS", message: "textureId is required", details: nil))
        return
      }
      let session: PipSession
      if let current = self.session, current.textureId == textureId {
        session = current
      } else {
        tearDown()
        session = PipSession(textureId: textureId) { [weak self] method, arguments in
          self?.channel.invokeMethod(method, arguments: arguments)
        }
        session.onStop = { [weak self, weak session] in
          // Keep the session alive while armed for auto-enter.
          guard let self, let session, self.session === session,
            !session.autoEnter
          else { return }
          self.tearDown()
        }
        self.session = session
      }
      session.configure(
        width: (args["width"] as? NSNumber)?.doubleValue ?? 16,
        height: (args["height"] as? NSNumber)?.doubleValue ?? 9
      )
      session.update(args)
      if args["autoEnter"] as? Bool == true {
        session.autoEnter = true
      } else {
        session.start()
      }
      result(nil)
    case "update":
      session?.update(args)
      result(nil)
    case "disableAutoEnter":
      if let session {
        session.autoEnter = false
        if !session.isActive {
          tearDown()
        }
      }
      result(nil)
    case "dispose":
      tearDown()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @available(iOS 15.0, *)
  private func tearDown() {
    session?.invalidate()
    session = nil
  }
}

// MARK: - Session

@available(iOS 15.0, *)
private final class PipSession: NSObject {
  /// Frame interval used while armed for auto-enter but not yet in PiP: the
  /// layer is not visible then, it only needs a recent frame to start from.
  private static let idleFrameInterval = 2.0
  /// Delay before retrying a resize refresh whose frame was not enqueued, so
  /// that a flush or released buffers can take effect first.
  private static let resizeRetryDelay = 0.1

  let textureId: Int64
  var onStop: (() -> Void)?
  private(set) var isActive = false

  var autoEnter = false {
    didSet { updateAutoEnter() }
  }

  private let sendEvent: (String, Any?) -> Void
  private let sourceView: SampleBufferView
  private let displayLayer: AVSampleBufferDisplayLayer
  private let timebase: CMTimebase
  private var controller: AVPictureInPictureController!
  private var possibleObservation: NSKeyValueObservation?
  private var observers: [NSObjectProtocol] = []
  private var enteredBackground = false

  private var isPlaying = false
  private var isLive = false
  private var speed = 1.0
  private var duration = CMTime.zero
  private var pendingStart = false
  private var stopRequested = false
  private var restoring = false
  /// Whether to leave the app once PiP has started, see `start()`.
  private var backgroundOnStart = false
  /// Tracks the frame being copied, the refreshes still owed and the PiP run
  /// they belong to.
  private var refreshGate = PipRefreshGate()
  /// The PiP run and invalidation, readable off the main thread.
  private let runState = PipRunState()
  /// The one armed retry of a resize refresh, see `scheduleResizeRetry()`.
  private var resizeRetry: DispatchWorkItem?
  /// Last display scale seen while the source view was attached, used when
  /// it is not (anymore) once the PiP window is resized.
  private var cachedDisplayScale: CGFloat = 0
  private var lastFrameTime: CFTimeInterval = 0
  /// Whether a frame has been enqueued, PiP shows a black window otherwise.
  private var hasFrame = false
  private var invalidated = false
  private let pipeline: FramePipeline

  init(textureId: Int64, sendEvent: @escaping (String, Any?) -> Void) {
    let sourceView = SampleBufferView()
    let displayLayer = sourceView.layer as! AVSampleBufferDisplayLayer
    displayLayer.videoGravity = .resizeAspect
    var timebase: CMTimebase?
    CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(),
      timebaseOut: &timebase
    )
    // Drives the progress shown in the PiP window.
    displayLayer.controlTimebase = timebase

    self.textureId = textureId
    self.sendEvent = sendEvent
    self.sourceView = sourceView
    self.displayLayer = displayLayer
    self.timebase = timebase!
    self.pipeline = FramePipeline(displayLayer: displayLayer, timebase: timebase!)
    super.init()

    controller = AVPictureInPictureController(
      contentSource: .init(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
    )
    controller.delegate = self
    controller.canStartPictureInPictureAutomaticallyFromInline = false
    possibleObservation = controller.observe(\.isPictureInPicturePossible) {
      [weak self] _, _ in
      DispatchQueue.main.async { self?.startIfPending() }
    }
    // The video is shown inline again once the app is back in the foreground.
    // Starting PiP also posts foreground notifications, and stopping it is
    // ignored until the scene is active, hence `didActivate` after background.
    observers = [
      NotificationCenter.default.addObserver(
        forName: UIScene.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        // Also posted while active when PiP stops.
        if UIApplication.shared.applicationState == .background {
          self?.enteredBackground = true
        }
      },
      NotificationCenter.default.addObserver(
        forName: UIScene.didActivateNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self, self.enteredBackground else { return }
        self.enteredBackground = false
        if self.controller.isPictureInPictureActive {
          self.stopRequested = true
          self.controller.stopPictureInPicture()
        }
      },
    ]
  }

  /// Places the (hidden) source layer where the player usually is, so the
  /// system's start/stop animation roughly matches the inline video.
  func configure(width: Double, height: Double) {
    guard let window = Self.hostWindow() else { return }
    if sourceView.superview !== window {
      // Below the Flutter view: it must be in the window, but not visible.
      window.insertSubview(sourceView, at: 0)
    }
    _ = resolveDisplayScale()
    let aspectRatio = width > 0 && height > 0 ? width / height : 16 / 9
    let bounds = window.bounds
    var size = CGSize(width: bounds.width, height: bounds.width / aspectRatio)
    if size.height > bounds.height {
      size = CGSize(width: bounds.height * aspectRatio, height: bounds.height)
    }
    let y =
      bounds.height > bounds.width
      ? window.safeAreaInsets.top : (bounds.height - size.height) / 2
    sourceView.frame = CGRect(
      x: (bounds.width - size.width) / 2,
      y: y,
      width: size.width,
      height: size.height
    )
    frameAvailable(force: true)
  }

  func update(_ args: [String: Any]) {
    if let value = args["isPlaying"] as? Bool { isPlaying = value }
    if let value = args["isLive"] as? Bool { isLive = value }
    if let value = (args["duration"] as? NSNumber)?.int64Value {
      duration = CMTime(value: value, timescale: 1000)
    }
    if let value = (args["speed"] as? NSNumber)?.doubleValue { speed = value }
    if let position = (args["position"] as? NSNumber)?.int64Value {
      let isBuffering = args["isBuffering"] as? Bool ?? false
      CMTimebaseSetRateAndAnchorTime(
        timebase,
        rate: isPlaying && !isBuffering ? speed : 0,
        anchorTime: CMTime(value: position, timescale: 1000),
        immediateSourceTime: CMClockGetTime(CMClockGetHostTimeClock())
      )
    }
    controller.invalidatePlaybackState()
  }

  /// Enters PiP and then leaves the app, so that the video only plays in the
  /// PiP window, as on Android where the whole activity becomes the window.
  func start() {
    guard !controller.isPictureInPictureActive else { return }
    pendingStart = true
    backgroundOnStart = true
    startIfPending()
    // Give up if PiP doesn't become possible shortly, so a stale request
    // doesn't start PiP unexpectedly later.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      guard let self, self.pendingStart else { return }
      self.pendingStart = false
      self.backgroundOnStart = false
      self.sendEvent("onStateChanged", ["active": false, "error": "PiP is not possible"])
      self.onStop?()
    }
  }

  private func startIfPending() {
    guard pendingStart, hasFrame, controller.isPictureInPicturePossible else { return }
    pendingStart = false
    controller.startPictureInPicture()
  }

  private func updateAutoEnter() {
    // AVKit may start PiP as soon as the app goes to background.
    controller.canStartPictureInPictureAutomaticallyFromInline = autoEnter && hasFrame
  }

  func invalidate() {
    invalidated = true
    pendingStart = false
    // Drops queued resize completions, retries and pending refreshes.
    advanceRun()
    possibleObservation?.invalidate()
    observers.forEach(NotificationCenter.default.removeObserver)
    controller.delegate = nil
    if controller.isPictureInPictureActive {
      controller.stopPictureInPicture()
    }
    if isActive {
      isActive = false
      sendEvent("onStateChanged", ["active": false])
    }
    // The content source retains its playback delegate (`self`).
    controller.contentSource = nil
    sourceView.removeFromSuperview()
    // Releases every frame still held by the layer and the buffer pool.
    pipeline.shutdown()
  }

  // MARK: Frames

  /// Must be called on the main thread.
  func frameAvailable(force: Bool = false) {
    // A forced refresh (resize, start) asked for while a frame is in flight is
    // done once that frame is finished, as a paused video sends no new frames.
    guard !invalidated, refreshGate.shouldStart(force: force) else { return }
    if !isActive {
      // Nothing shows the layer while in background without PiP, so what is
      // enqueued then would only pile up.
      if UIApplication.shared.applicationState == .background { return }
      // One frame to start from, then only an occasional refresh.
      if !force && hasFrame && !pendingStart
        && CACurrentMediaTime() - lastFrameTime < Self.idleFrameInterval
      {
        return
      }
    }
    guard let texture = TextureTracker.texture(for: textureId),
      let source = texture.copyPixelBuffer()?.takeRetainedValue()
    else { return }
    lastFrameTime = CACurrentMediaTime()
    refreshGate.started()
    // This frame is an attempt for the resize, an armed retry would be another.
    if refreshGate.inFlightCarriesResize {
      cancelResizeRetry()
    }
    // mpv renders into the source buffer again about a frame after it stops
    // being the current one, so `submit` copies it (and downscales it if
    // needed) before returning, the layer only ever gets the copy.
    pipeline.submit(source, isPipActive: isActive) { [weak self] enqueued in
      guard let self else { return }
      let next = self.refreshGate.finished(enqueued: enqueued)
      // Enqueued at the new size, or given up: an armed retry is not needed.
      if !self.refreshGate.hasPendingResize {
        self.cancelResizeRetry()
      }
      if !self.invalidated, enqueued, !self.hasFrame {
        self.hasFrame = true
        self.updateAutoEnter()
        self.startIfPending()
      }
      switch next {
      case .none:
        break
      case .refresh:
        self.frameAvailable(force: true)
      case .retryResize:
        self.scheduleResizeRetry()
      case .resizeAbandoned:
        FramePipeline.log.notice(
          "PiP resize refresh abandoned after \(PipRefreshGate.maxResizeAttempts) attempts"
        )
      }
    }
  }

  /// Asks for a frame at the PiP window size set by `pipeline.setRenderSize`
  /// in the PiP run `generation`. A paused video sends no new frames, so the
  /// refresh is retried a few times if its frame is not enqueued.
  private func requestResizeRefresh(generation: UInt64) {
    guard !invalidated, isActive, refreshGate.requestResize(generation: generation) else {
      FramePipeline.log.notice("Stale PiP resize refresh discarded")
      return
    }
    // Replaces the retry of the previous resize.
    cancelResizeRetry()
    frameAvailable(force: true)
  }

  /// Arms the retry of the current resize, replacing any armed one. The retry
  /// is cancelled once the resize is enqueued, given up or replaced, or the
  /// PiP run ends, and checks the resize and run again if already dequeued.
  private func scheduleResizeRetry() {
    cancelResizeRetry()
    let generation = refreshGate.generation
    let sequence = refreshGate.resizeSequence
    let retry = DispatchWorkItem { [weak self] in
      guard let self, !self.invalidated, self.isActive,
        self.refreshGate.isResizeRetryCurrent(sequence: sequence, generation: generation)
      else { return }
      self.frameAvailable(force: true)
    }
    resizeRetry = retry
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeRetryDelay, execute: retry)
  }

  private func cancelResizeRetry() {
    resizeRetry?.cancel()
    resizeRetry = nil
  }

  /// Ends the current PiP run: what is owed to it is dropped, and callbacks
  /// made during it are ignored, see `runState`.
  private func advanceRun() {
    refreshGate.advanceGeneration()
    cancelResizeRetry()
    runState.publish(generation: refreshGate.generation, invalidated: invalidated)
  }

  /// Scale of the screen showing the app. The source view may be detached or
  /// the app in background while PiP is resized, so the last scale seen while
  /// attached is used before falling back to the main screen.
  private func resolveDisplayScale() -> CGFloat {
    let window = sourceView.window
    let windowScale = window?.windowScene?.screen.scale ?? window?.screen.scale
    let traitScale = sourceView.traitCollection.displayScale
    if let live = PipFrameSizing.validScale(windowScale) ?? PipFrameSizing.validScale(traitScale) {
      cachedDisplayScale = live
    }
    return PipFrameSizing.displayScale(
      windowScale: windowScale,
      traitScale: traitScale,
      cachedScale: cachedDisplayScale,
      mainScale: UIScreen.main.scale
    )
  }

  /// Same as the home gesture. There is no public API for this, `suspend` is
  /// a private method of `UIApplication`.
  private static func moveToBackground() {
    UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
  }

  private static func hostWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    return windows.first { $0.rootViewController is FlutterViewController }
      ?? windows.first { $0.isKeyWindow }
  }
}

@available(iOS 15.0, *)
extension PipSession: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    isActive = true
    stopRequested = false
    restoring = false
    pipeline.resetDiagnostics()
    frameAvailable(force: true)
    sendEvent("onStateChanged", ["active": true])
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    if backgroundOnStart {
      backgroundOnStart = false
      Self.moveToBackground()
    }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    isActive = false
    backgroundOnStart = false
    sendEvent("onStateChanged", ["active": false, "error": error.localizedDescription])
    DispatchQueue.main.async { [weak self] in self?.onStop?() }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    restoring = true
    completionHandler(true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    isActive = false
    // Refreshes owed to this PiP run must not enqueue after it, the session
    // survives while armed for auto-enter and forced refreshes skip its throttle.
    advanceRun()
    // Neither restored nor stopped by the app: closed from the PiP window.
    let closed = !restoring && !stopRequested
    stopRequested = false
    restoring = false
    sendEvent("onStateChanged", ["active": false, "closed": closed])
    // Nothing consumes the frames queued for the PiP window anymore.
    pipeline.flush()
    DispatchQueue.main.async { [weak self] in self?.onStop?() }
  }
}

@available(iOS 15.0, *)
extension PipSession: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    isPlaying = playing
    CMTimebaseSetRate(timebase, rate: playing ? speed : 0)
    pictureInPictureController.invalidatePlaybackState()
    sendEvent("setPlaying", playing)
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    if isLive || !(duration.seconds > 0) {
      return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    return CMTimeRange(start: .zero, duration: duration)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    !isPlaying
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {
    // The run is read before any hop to the main thread, so that a callback
    // made during a run that has stopped since is not applied to the next.
    let run = runState.snapshot()
    guard !run.invalidated else { return }
    // Reads UIKit state and the session's, both main thread only.
    if Thread.isMainThread {
      applyRenderSize(newRenderSize, generation: run.generation)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.applyRenderSize(newRenderSize, generation: run.generation)
      }
    }
  }

  /// Main thread only. `generation` is the PiP run the size was reported in.
  private func applyRenderSize(_ newRenderSize: CMVideoDimensions, generation: UInt64) {
    let run = runState.snapshot()
    guard !invalidated, !run.invalidated, run.generation == generation else {
      FramePipeline.log.notice(
        "Stale AVKit render size discarded: \(newRenderSize.width)x\(newRenderSize.height)"
      )
      return
    }
    // Documented as pixels, but AVKit reports points at runtime, as the
    // source view's layout. Logged raw so a device log shows which it is.
    let scale = resolveDisplayScale()
    guard
      let pixels = PipFrameSizing.renderPixels(
        width: Double(newRenderSize.width),
        height: Double(newRenderSize.height),
        scale: scale
      )
    else {
      FramePipeline.log.notice(
        "AVKit render size ignored: \(newRenderSize.width)x\(newRenderSize.height)"
      )
      return
    }
    FramePipeline.log.notice(
      "AVKit render size: raw \(newRenderSize.width)x\(newRenderSize.height), displayScale \(Double(scale), format: .fixed(precision: 2)), target \(Double(pixels.width), format: .fixed(precision: 1))x\(Double(pixels.height), format: .fixed(precision: 1)) px"
    )
    // Kept even if PiP is not active yet, the refresh then waits for its start.
    pipeline.setRenderSize(pixels) { [weak self] in
      self?.requestResizeRefresh(generation: generation)
    }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    let target = CMTimeClampToRange(
      CMTimeAdd(CMTimebaseGetTime(timebase), skipInterval),
      range: CMTimeRange(start: .zero, duration: duration)
    )
    CMTimebaseSetTime(timebase, time: target)
    sendEvent("skip", Int((skipInterval.seconds * 1000).rounded()))
    completionHandler()
  }

  func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    false
  }
}

// MARK: - Sizing

/// Size of the frames sent to PiP. Pure functions, no UIKit.
private enum PipFrameSizing {
  /// Upper bound of the longest side of the frames sent to PiP: a 3x screen's
  /// largest PiP window at 1:1, 6 BGRA buffers stay under 24 MiB.
  static let maxDimension = 1280.0
  /// Upper bound of the pixels of a frame (1280x720), bounds portrait videos.
  static let maxPixelCount = 921_600.0
  /// Upper bound of the longest side while the PiP window size is unknown.
  static let idleMaxDimension = 960.0

  static func validScale(_ scale: CGFloat?) -> CGFloat? {
    guard let scale, scale.isFinite, scale > 0 else { return nil }
    return scale
  }

  /// First valid scale of the window's screen, the view's traits, the cached
  /// one and the main screen, at least 1.
  static func displayScale(
    windowScale: CGFloat?,
    traitScale: CGFloat?,
    cachedScale: CGFloat?,
    mainScale: CGFloat
  ) -> CGFloat {
    let scale =
      validScale(windowScale) ?? validScale(traitScale) ?? validScale(cachedScale)
      ?? validScale(mainScale) ?? 1
    return max(1, scale)
  }

  /// PiP window size in pixels from a render size in points, `nil` if empty.
  static func renderPixels(width: Double, height: Double, scale: CGFloat) -> CGSize? {
    guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
    let scale = Double(validScale(scale) ?? 1)
    return CGSize(width: width * max(1, scale), height: height * max(1, scale))
  }

  /// Size of the copy of a `sourceWidth` x `sourceHeight` frame: fits in the
  /// render size (aspect fit, as the layer), never upscaled, capped, with even
  /// sides rounded down. `nil` if the source is empty.
  static func frameSize(sourceWidth: Double, sourceHeight: Double, renderSize: CGSize?)
    -> CGSize?
  {
    guard sourceWidth.isFinite, sourceHeight.isFinite, sourceWidth > 0, sourceHeight > 0
    else { return nil }
    let longest = max(sourceWidth, sourceHeight)
    let pixelCap = (maxPixelCount / (sourceWidth * sourceHeight)).squareRoot()
    var scale = min(1, pixelCap)
    if let renderSize, renderSize.width > 0, renderSize.height > 0 {
      scale = min(
        scale,
        maxDimension / longest,
        renderSize.width / sourceWidth,
        renderSize.height / sourceHeight
      )
    } else {
      scale = min(scale, idleMaxDimension / longest)
    }
    return CGSize(
      width: alignDown(sourceWidth * scale, source: sourceWidth),
      height: alignDown(sourceHeight * scale, source: sourceHeight)
    )
  }

  /// Even value at most `value`, at least 2 and at most `source`.
  static func alignDown(_ value: Double, source: Double) -> Double {
    let source = source.rounded(.down)
    if source < 2 { return max(1, source) }
    // The tolerance keeps exact products (1169.9999...) from losing 2 pixels.
    let even = ((value + 1e-6) / 2).rounded(.down) * 2
    return min(max(2, even), source)
  }
}

/// Lets one frame be copied at a time and tracks the refreshes still owed:
/// a forced refresh asked for meanwhile, done once the frame is finished, and
/// a resize refresh, retried a few times until its frame is enqueued.
///
/// Both belong to a PiP run, `generation`: advancing it drops them, and a
/// resize asked for in an earlier run is refused.
private struct PipRefreshGate {
  enum Next: Equatable {
    case none
    /// A forced refresh was asked for while the frame was in flight.
    case refresh
    /// The frame owed to a resize was not enqueued, try again.
    case retryResize
    /// The frame owed to a resize was not enqueued, and that was the last try.
    case resizeAbandoned
  }

  /// Frames tried per resize before giving up.
  static let maxResizeAttempts = 3

  private(set) var generation: UInt64 = 0
  private(set) var frameInFlight = false
  /// Generation of a forced refresh asked for while a frame was in flight.
  private(set) var pendingRefreshGeneration: UInt64?
  /// Frames left to try for the last resize, 0 once enqueued or given up.
  private(set) var resizeAttemptsLeft = 0
  /// Whether the frame in flight was started at the last resize's size.
  private(set) var inFlightCarriesResize = false
  /// Number of the last resize, a retry only serves the resize it was armed for.
  private(set) var resizeSequence: UInt64 = 0

  var pendingForcedRefresh: Bool { pendingRefreshGeneration == generation }
  var hasPendingResize: Bool { resizeAttemptsLeft > 0 }

  /// Whether a retry armed for resize `sequence` in run `generation` is due:
  /// not if a frame in flight is already an attempt for it, as the forced
  /// refresh it would leave pending would hide that attempt's outcome.
  func isResizeRetryCurrent(sequence: UInt64, generation: UInt64) -> Bool {
    generation == self.generation && sequence == resizeSequence && hasPendingResize
      && !(frameInFlight && inFlightCarriesResize)
  }

  /// Starts a new PiP run, dropping what is owed to the previous one.
  mutating func advanceGeneration() {
    generation &+= 1
    pendingRefreshGeneration = nil
    resizeAttemptsLeft = 0
    inFlightCarriesResize = false
  }

  /// Owes a frame at a new render size, unless asked for in an earlier run.
  mutating func requestResize(generation: UInt64) -> Bool {
    guard generation == self.generation else { return false }
    resizeSequence &+= 1
    resizeAttemptsLeft = Self.maxResizeAttempts
    // The frame in flight may have been copied at the previous size.
    inFlightCarriesResize = false
    return true
  }

  /// Whether a frame may be started now.
  mutating func shouldStart(force: Bool) -> Bool {
    guard frameInFlight else { return true }
    if force { pendingRefreshGeneration = generation }
    return false
  }

  mutating func started() {
    frameInFlight = true
    inFlightCarriesResize = resizeAttemptsLeft > 0
  }

  /// Ends the frame, returns what to do next.
  mutating func finished(enqueued: Bool) -> Next {
    frameInFlight = false
    let refresh = pendingForcedRefresh
    pendingRefreshGeneration = nil
    var next = Next.none
    if inFlightCarriesResize {
      inFlightCarriesResize = false
      if enqueued {
        resizeAttemptsLeft = 0
      } else {
        resizeAttemptsLeft = max(0, resizeAttemptsLeft - 1)
        next = resizeAttemptsLeft > 0 ? .retryResize : .resizeAbandoned
      }
    }
    // The refresh is started right away and carries the resize if still owed.
    return refresh ? .refresh : next
  }
}

/// The PiP run (`PipRefreshGate.generation`) and whether the session is
/// invalidated, readable from any thread. Written on the main thread.
private final class PipRunState {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var invalidated = false

  func snapshot() -> (generation: UInt64, invalidated: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (generation, invalidated)
  }

  func publish(generation: UInt64, invalidated: Bool) {
    lock.lock()
    defer { lock.unlock() }
    self.generation = generation
    self.invalidated = invalidated
  }
}

// MARK: - Frame pipeline

/// Copies frames into a bounded pool of pixel buffers and feeds them to the
/// display layer.
///
/// A pool buffer is only recycled once every holder has released it, and that
/// includes the system processes rendering the layer. The pool is therefore
/// capped: when the system does not give buffers back, frames are dropped and
/// the layer is flushed instead of allocating without limit, which ends with
/// the system killing its render server.
///
/// The methods can be called from any thread but `queue`, the state is only
/// accessed on `queue`. The layer is only changed (enqueue, flush) by blocks
/// running asynchronously on `queue`, so a caller waiting for a copy never
/// waits for the layer. Completion handlers are called on the main thread.
@available(iOS 15.0, *)
private final class FramePipeline {
  /// Result of copying a frame, the parts that change the layer are left to
  /// `deliver(_:)`.
  private enum Snapshot {
    case copied(CVPixelBuffer)
    case dropped(String)
    case flushNeeded
    case failed
  }

  /// Number of pixel buffers that may be alive at once.
  private static let maxBufferCount = 6
  /// Number of consecutive dropped frames after which the layer is flushed again.
  private static let flushAfterDrops = 30
  static let log = Logger(subsystem: "com.example.piliplus", category: "PiP")
  private static let diagnosticsInterval: CFTimeInterval = 5

  private let queue = DispatchQueue(label: "com.example.piliplus.pip.frame")
  private let timebase: CMTimebase
  private let ciContext = CIContext(options: [
    .workingColorSpace: NSNull(),
    .outputColorSpace: NSNull(),
    .cacheIntermediates: false,
  ])
  private let allocationAttributes =
    [kCVPixelBufferPoolAllocationThresholdKey: FramePipeline.maxBufferCount] as CFDictionary
  /// `nil` once shut down.
  private var displayLayer: AVSampleBufferDisplayLayer?
  private var pool: CVPixelBufferPool?
  private var poolSize = CGSize.zero
  private var formatDescription: CMVideoFormatDescription?
  /// Size of the PiP window in pixels, zero until known.
  private var renderSizePixels = CGSize.zero
  private var consecutiveDrops = 0
  private var lastPresentationTime = CMTime.invalid
  private var lastLogTime: CFTimeInterval = 0
  private var lastDiagnosticsTime: CFTimeInterval = 0
  private var snapshotDuration: CFTimeInterval = 0
  private var submittedFrames = 0
  private var droppedFrames = 0
  /// Set when the pool was replaced, frames of the previous size still hold
  /// its buffers until the layer is flushed.
  private var flushBeforeEnqueue = false

  init(displayLayer: AVSampleBufferDisplayLayer, timebase: CMTimebase) {
    self.displayLayer = displayLayer
    self.timebase = timebase
  }

  /// Copies `source` before returning, `source` is not accessed afterwards.
  /// Then enqueues the copy, `completion` tells whether it was.
  func submit(
    _ source: CVPixelBuffer,
    isPipActive: Bool,
    completion: @escaping (Bool) -> Void
  ) {
    dispatchPrecondition(condition: .notOnQueue(queue))
    // Temporary objects keep buffers of the pool alive until they are released.
    let (snapshot, duration) = queue.sync {
      let start = isPipActive ? CACurrentMediaTime() : 0
      let snapshot = autoreleasepool { self.snapshot(source) }
      return (snapshot, isPipActive ? CACurrentMediaTime() - start : 0)
    }
    queue.async {
      let enqueued = autoreleasepool { self.deliver(snapshot) }
      if isPipActive {
        self.recordSnapshot(duration: duration, enqueued: enqueued)
      }
      DispatchQueue.main.async { completion(enqueued) }
    }
  }

  /// `size` is the PiP window size in pixels, see `PipFrameSizing`.
  func setRenderSize(_ size: CGSize, completion: @escaping () -> Void) {
    queue.async {
      self.renderSizePixels = size
      DispatchQueue.main.async(execute: completion)
    }
  }

  func resetDiagnostics() {
    queue.async { self.resetDiagnostics(at: CACurrentMediaTime()) }
  }

  /// Discards the frames queued in the layer, the displayed one is kept.
  func flush() {
    queue.async { self.flushLayer(removingImage: false) }
  }

  /// Releases all frames and buffers, nothing is enqueued afterwards.
  func shutdown() {
    queue.async {
      self.flushLayer(removingImage: true)
      self.pool = nil
      self.formatDescription = nil
      self.ciContext.clearCaches()
      // The layer backs a view, so hand this reference over to the main thread
      // instead of dropping it here.
      DispatchQueue.main.async { [layer = self.displayLayer] in
        withExtendedLifetime(layer) {}
      }
      self.displayLayer = nil
    }
  }

  // MARK: On `queue`

  private func resetDiagnostics(at time: CFTimeInterval) {
    lastDiagnosticsTime = time
    snapshotDuration = 0
    submittedFrames = 0
    droppedFrames = 0
  }

  private func recordSnapshot(duration: CFTimeInterval, enqueued: Bool) {
    snapshotDuration += duration
    submittedFrames += 1
    if !enqueued { droppedFrames += 1 }
    let now = CACurrentMediaTime()
    guard now - lastDiagnosticsTime >= Self.diagnosticsInterval else { return }

    let averageMs = snapshotDuration * 1000 / Double(submittedFrames)
    let width = Int(poolSize.width)
    let height = Int(poolSize.height)
    Self.log.notice(
      "Pool size: \(width)x\(height) px, average snapshot: \(averageMs, format: .fixed(precision: 2)) ms, dropped: \(self.droppedFrames)/\(self.submittedFrames) submitted frames"
    )
    resetDiagnostics(at: now)
  }

  /// Copies `source` unless the frame would be dropped anyway. Only reads the
  /// state of the layer.
  private func snapshot(_ source: CVPixelBuffer) -> Snapshot {
    guard let displayLayer else { return .failed }
    if Self.needsFlush(displayLayer) { return .flushNeeded }
    guard Self.isReady(displayLayer) else { return .dropped("the layer is not ready") }
    return copy(source)
  }

  private func deliver(_ snapshot: Snapshot) -> Bool {
    guard let displayLayer else { return false }
    if flushBeforeEnqueue {
      flushBeforeEnqueue = false
      flushLayer(removingImage: false)
    }
    let copy: CVPixelBuffer
    switch snapshot {
    case .copied(let pixelBuffer):
      copy = pixelBuffer
    case .dropped(let reason):
      dropped(reason)
      return false
    case .flushNeeded:
      flushLayer(removingImage: false)
      return false
    case .failed:
      return false
    }
    guard let sampleBuffer = makeSampleBuffer(copy) else { return false }
    let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if lastPresentationTime.isValid && CMTimeCompare(time, lastPresentationTime) < 0 {
      // Seeked backwards: the frames queued for a later time are stale.
      flushLayer(removingImage: false)
    }
    let enqueued = Self.enqueue(sampleBuffer, to: displayLayer)
    if enqueued {
      lastPresentationTime = time
      consecutiveDrops = 0
    }
    return enqueued
  }

  private func dropped(_ reason: String) {
    consecutiveDrops += 1
    // Flushing makes the layer give up the frames it holds, and with them the
    // buffers. Right away, then again for as long as nothing gets through.
    if consecutiveDrops % Self.flushAfterDrops == 1 {
      flushLayer(removingImage: false)
    }
    let now = CACurrentMediaTime()
    if now - lastLogTime >= 5 {
      lastLogTime = now
      NSLog("PipPlugin: dropped \(consecutiveDrops) frame(s), \(reason)")
    }
  }

  private func flushLayer(removingImage: Bool) {
    lastPresentationTime = .invalid
    guard let displayLayer else { return }
    if #available(iOS 17.0, *) {
      displayLayer.sampleBufferRenderer.flush(
        removingDisplayedImage: removingImage,
        completionHandler: nil
      )
    } else if removingImage {
      displayLayer.flushAndRemoveImage()
    } else {
      displayLayer.flush()
    }
  }

  private static func needsFlush(_ displayLayer: AVSampleBufferDisplayLayer) -> Bool {
    if #available(iOS 17.0, *) {
      let renderer = displayLayer.sampleBufferRenderer
      return renderer.status == .failed || renderer.requiresFlushToResumeDecoding
    } else {
      return displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding
    }
  }

  private static func isReady(_ displayLayer: AVSampleBufferDisplayLayer) -> Bool {
    if #available(iOS 17.0, *) {
      return displayLayer.sampleBufferRenderer.isReadyForMoreMediaData
    } else {
      return displayLayer.isReadyForMoreMediaData
    }
  }

  private static func enqueue(
    _ sampleBuffer: CMSampleBuffer,
    to displayLayer: AVSampleBufferDisplayLayer
  ) -> Bool {
    if #available(iOS 17.0, *) {
      let renderer = displayLayer.sampleBufferRenderer
      renderer.enqueue(sampleBuffer)
      return renderer.status != .failed
    } else {
      displayLayer.enqueue(sampleBuffer)
      return displayLayer.status != .failed
    }
  }

  private func copy(_ source: CVPixelBuffer) -> Snapshot {
    let sourceWidth = Double(CVPixelBufferGetWidth(source))
    let sourceHeight = Double(CVPixelBufferGetHeight(source))
    let hasRenderSize = renderSizePixels.width > 0 && renderSizePixels.height > 0
    // No need for more pixels than the PiP window has.
    guard
      let size = PipFrameSizing.frameSize(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        renderSize: hasRenderSize ? renderSizePixels : nil
      )
    else { return .failed }

    if pool == nil || poolSize != size {
      // Frames of the previous size keep the buffers of the previous pool alive.
      flushBeforeEnqueue = true
      pool = nil
      poolSize = size
      Self.log.notice(
        "Pool size changed: \(Int(size.width))x\(Int(size.height)) px for a \(Int(sourceWidth))x\(Int(sourceHeight)) source, render size \(Double(self.renderSizePixels.width), format: .fixed(precision: 1))x\(Double(self.renderSizePixels.height), format: .fixed(precision: 1)) px"
      )
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: Int(size.width),
        kCVPixelBufferHeightKey: Int(size.height),
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
      ]
      CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }
    guard let pool else { return .failed }

    var output: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
      nil,
      pool,
      allocationAttributes,
      &output
    )
    if status == kCVReturnWouldExceedAllocationThreshold {
      return .dropped("all \(Self.maxBufferCount) buffers are in use")
    }
    guard status == kCVReturnSuccess, let output else { return .failed }

    var image = CIImage(cvPixelBuffer: source)
    if size.width != sourceWidth || size.height != sourceHeight {
      image = image.transformed(
        by: CGAffineTransform(
          scaleX: size.width / sourceWidth,
          y: size.height / sourceHeight
        )
      )
    }
    let destination = CIRenderDestination(pixelBuffer: output)
    // Not color matched, as the context.
    destination.colorSpace = nil
    do {
      // Waits for the GPU, the source must not be read after returning.
      _ = try ciContext.startTask(toRender: image, to: destination).waitUntilCompleted()
    } catch {
      NSLog("PipPlugin: copying a frame failed: \(error)")
      return .failed
    }
    return .copied(output)
  }

  private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
    let matches =
      formatDescription.map {
        CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer)
      } ?? false
    if !matches {
      formatDescription = nil
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: nil,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
      )
    }
    guard let formatDescription else { return nil }

    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMTimebaseGetTime(timebase),
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: nil,
      imageBuffer: pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard let sampleBuffer else { return nil }

    // Frames are already paced by mpv.
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: true
    ), CFArrayGetCount(attachments) > 0 {
      let dict = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0),
        to: CFMutableDictionary.self
      )
      CFDictionarySetValue(
        dict,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
    return sampleBuffer
  }
}

private final class SampleBufferView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
}

// MARK: - Texture tracking

/// Hooks the engine's `FlutterTextureRegistry` to keep track of registered
/// textures and to observe their frame updates. Main thread only.
private enum TextureTracker {
  private final class WeakTexture {
    weak var value: FlutterTexture?
    init(_ value: FlutterTexture) { self.value = value }
  }

  private static var textures = [Int64: WeakTexture]()
  private static var installed = false

  static var onFrameAvailable: ((Int64) -> Void)?

  static func texture(for textureId: Int64) -> FlutterTexture? {
    textures[textureId]?.value
  }

  static func install(on registry: FlutterTextureRegistry) {
    guard !installed, let cls = object_getClass(registry) else { return }
    installed = true

    let registerSelector = NSSelectorFromString("registerTexture:")
    hook(cls, registerSelector) { original in
      typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> Int64
      let function = unsafeBitCast(original, to: Function.self)
      let block: @convention(block) (AnyObject, AnyObject) -> Int64 = { this, texture in
        let textureId = function(this, registerSelector, texture)
        if let texture = texture as? FlutterTexture {
          Self.textures = Self.textures.filter { $0.value.value != nil }
          Self.textures[textureId] = WeakTexture(texture)
        }
        return textureId
      }
      return unsafeBitCast(block, to: AnyObject.self)
    }

    let frameAvailableSelector = NSSelectorFromString("textureFrameAvailable:")
    hook(cls, frameAvailableSelector) { original in
      typealias Function = @convention(c) (AnyObject, Selector, Int64) -> Void
      let function = unsafeBitCast(original, to: Function.self)
      let block: @convention(block) (AnyObject, Int64) -> Void = { this, textureId in
        function(this, frameAvailableSelector, textureId)
        Self.onFrameAvailable?(textureId)
      }
      return unsafeBitCast(block, to: AnyObject.self)
    }
  }

  private static func hook(
    _ cls: AnyClass,
    _ selector: Selector,
    _ makeBlock: (IMP) -> AnyObject
  ) {
    guard let method = class_getInstanceMethod(cls, selector) else {
      NSLog("PipPlugin: \(cls) does not respond to \(selector)")
      return
    }
    let imp = imp_implementationWithBlock(makeBlock(method_getImplementation(method)))
    // Add an override if the method is inherited, so the superclass is untouched.
    if !class_addMethod(cls, selector, imp, method_getTypeEncoding(method)) {
      method_setImplementation(method, imp)
    }
  }
}
