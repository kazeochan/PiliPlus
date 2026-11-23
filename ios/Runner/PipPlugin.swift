import AVKit
import CoreImage
import Flutter
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
  private var frameInFlight = false
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
    guard !invalidated, !frameInFlight else { return }
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
    frameInFlight = true
    // mpv renders into the source buffer again about a frame after it stops
    // being the current one, so `submit` copies it (and downscales it if
    // needed) before returning, the layer only ever gets the copy.
    pipeline.submit(source) { [weak self] enqueued in
      guard let self else { return }
      self.frameInFlight = false
      guard !self.invalidated, enqueued, !self.hasFrame else { return }
      self.hasFrame = true
      self.updateAutoEnter()
      self.startIfPending()
    }
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
    // Reported in points.
    let scale = max(sourceView.traitCollection.displayScale, 1)
    let size = CGSize(
      width: Double(newRenderSize.width) * scale,
      height: Double(newRenderSize.height) * scale
    )
    pipeline.setRenderSize(size) { [weak self] in
      self?.frameAvailable(force: true)
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

  /// Upper bound of the longest side of the frames sent to PiP.
  private static let maxDimension = 1920.0
  /// Same, while the size of the PiP window is not known yet.
  private static let idleMaxDimension = 960.0
  /// Number of pixel buffers that may be alive at once.
  private static let maxBufferCount = 6
  /// Number of consecutive dropped frames after which the layer is flushed again.
  private static let flushAfterDrops = 30

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
  private var renderSize = CGSize.zero
  private var consecutiveDrops = 0
  private var lastPresentationTime = CMTime.invalid
  private var lastLogTime: CFTimeInterval = 0
  /// Set when the pool was replaced, frames of the previous size still hold
  /// its buffers until the layer is flushed.
  private var flushBeforeEnqueue = false

  init(displayLayer: AVSampleBufferDisplayLayer, timebase: CMTimebase) {
    self.displayLayer = displayLayer
    self.timebase = timebase
  }

  /// Copies `source` before returning, `source` is not accessed afterwards.
  /// Then enqueues the copy, `completion` tells whether it was.
  func submit(_ source: CVPixelBuffer, completion: @escaping (Bool) -> Void) {
    dispatchPrecondition(condition: .notOnQueue(queue))
    // Temporary objects keep buffers of the pool alive until they are released.
    let snapshot = queue.sync { autoreleasepool { self.snapshot(source) } }
    queue.async {
      let enqueued = autoreleasepool { self.deliver(snapshot) }
      DispatchQueue.main.async { completion(enqueued) }
    }
  }

  func setRenderSize(_ size: CGSize, completion: @escaping () -> Void) {
    queue.async {
      self.renderSize = size
      DispatchQueue.main.async(execute: completion)
    }
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
    guard sourceWidth > 0, sourceHeight > 0 else { return .failed }
    let hasRenderSize = renderSize.width > 0 && renderSize.height > 0
    let maxDimension = hasRenderSize ? Self.maxDimension : Self.idleMaxDimension
    var scale = min(1, maxDimension / max(sourceWidth, sourceHeight))
    if hasRenderSize {
      // No need for more pixels than the PiP window has.
      scale = min(
        scale,
        max(renderSize.width / sourceWidth, renderSize.height / sourceHeight)
      )
    }
    let size = CGSize(
      width: max(1, (sourceWidth * scale).rounded()),
      height: max(1, (sourceHeight * scale).rounded())
    )

    if pool == nil || poolSize != size {
      // Frames of the previous size keep the buffers of the previous pool alive.
      flushBeforeEnqueue = true
      pool = nil
      poolSize = size
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
    if scale < 1 {
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
