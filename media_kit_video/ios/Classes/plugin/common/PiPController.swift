// Picture-in-Picture support for media_kit on iOS.
//
// mpv keeps decoding & rendering frames into the CVPixelBuffer swapchain
// (driven by its own render-update callback, independent of Flutter's
// rasterizer). This controller taps those frames, wraps them into
// CMSampleBuffers and feeds an AVSampleBufferDisplayLayer, which is handed
// to AVPictureInPictureController as a sample-buffer content source
// (iOS 15+). The PiP window's play/pause/skip controls are forwarded
// straight to the mpv handle, so they keep working even while the Flutter
// engine is paused in the background.
#if os(iOS)
  import AVKit
  import CoreMedia
  import Foundation
  import UIKit

  /// Availability-safe entry point used by the render paths
  /// (`TextureHW`/`TextureSW`), which must compile for older deployment
  /// targets.
  public enum MediaKitPiP {
    public static func enqueue(_ pixelBuffer: CVPixelBuffer) {
      if #available(iOS 15.0, *) {
        MediaKitPiPController.shared.enqueue(pixelBuffer)
      }
    }
  }

  @available(iOS 15.0, *)
  final class SampleBufferDisplayView: UIView {
    override class var layerClass: AnyClass {
      AVSampleBufferDisplayLayer.self
    }

    var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
      layer as! AVSampleBufferDisplayLayer
    }
  }

  /// Off-screen-to-the-user sample-buffer host. Inserted *behind* Flutter's
  /// view so AVKit still sees a real, full-alpha inline layer (required for
  /// automatic PiP) without stacking a second picture on the player.
  @available(iOS 15.0, *)
  final class PiPHostView: UIView {
    let displayView = SampleBufferDisplayView()

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      backgroundColor = .clear
      displayView.backgroundColor = .black
      displayView.sampleBufferDisplayLayer.videoGravity = .resizeAspect
      addSubview(displayView)
    }

    required init?(coder: NSCoder) {
      return nil
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      displayView.frame = Self.videoRect(in: bounds)
    }

    /// 16:9, centered. No chrome insets — this view is never the on-screen
    /// player (Flutter paints that). The aspect just keeps AVKit's PiP
    /// window matching the video instead of the full device frame.
    static func videoRect(in bounds: CGRect) -> CGRect {
      let aspect: CGFloat = 16.0 / 9.0
      if bounds.height <= 0 || bounds.width <= 0 {
        return bounds
      }
      let boundsAspect = bounds.width / bounds.height
      if boundsAspect > aspect {
        let width = bounds.height * aspect
        return CGRect(
          x: bounds.midX - width / 2,
          y: 0,
          width: width,
          height: bounds.height
        )
      }
      let height = bounds.width / aspect
      return CGRect(
        x: 0,
        y: bounds.midY - height / 2,
        width: bounds.width,
        height: height
      )
    }
  }

  @available(iOS 15.0, *)
  public class MediaKitPiPController: NSObject {
    public static let shared = MediaKitPiPController()

    public static var isSupported: Bool {
      AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// Invoked with "willStart", "didStart", "didStop", "restore" or
    /// "failed" so the host app can react to PiP lifecycle changes.
    public var onEvent: ((String) -> Void)?

    private var mpvHandle: OpaquePointer?
    private var hostView: PiPHostView?
    private var pipController: AVPictureInPictureController?
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var lastFrameWidth = 0
    private var lastFrameHeight = 0
    private var frameCount = 0
    private var didInvalidatePlaybackState = false
    private var lifecycleObservers: [NSObjectProtocol] = []
    // Read from the render worker thread, written on the main thread.
    private var enabled = false

    public var isActive: Bool {
      pipController?.isPictureInPictureActive ?? false
    }

    private var displayLayer: AVSampleBufferDisplayLayer? {
      hostView?.displayView.sampleBufferDisplayLayer
    }

    // MARK: - Lifecycle

    /// `mpvHandle` is the address of the `mpv_handle` obtained from
    /// `Player.handle` on the Dart side.
    public func enable(mpvHandle: Int64) {
      DispatchQueue.main.async {
        self.attachAndEnable(mpvHandle)
      }
    }

    public func disable() {
      DispatchQueue.main.async {
        self.teardown()
      }
    }

    public func start() {
      DispatchQueue.main.async {
        self.startWhenPossible(attemptsLeft: 10)
      }
    }

    public func stop() {
      DispatchQueue.main.async {
        self.pipController?.stopPictureInPicture()
      }
    }

    private func attachAndEnable(_ handle: Int64) {
      mpvHandle = OpaquePointer(bitPattern: Int(handle))

      guard pipController == nil else {
        enabled = true
        return
      }
      guard Self.isSupported else {
        onEvent?("Picture in Picture is not supported on this device")
        return
      }
      guard
        let window = UIApplication.shared.connectedScenes
          .compactMap({ $0 as? UIWindowScene })
          .flatMap({ $0.windows })
          .first(where: { $0.isKeyWindow })
          ?? UIApplication.shared.windows.first
      else {
        onEvent?("no key window to host the display layer")
        return
      }

      // The audio session must be configured and active BEFORE the
      // AVPictureInPictureController is created, otherwise both manual and
      // automatic PiP starts fail with a generic error.
      do {
        try AVAudioSession.sharedInstance().setCategory(
          .playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
      } catch {
        onEvent?("audio session setup failed: \(error.localizedDescription)")
      }

      // AVKit's automatic start-from-inline only fires for a layer that is
      // in the window, un-hidden, and alpha == 1 for the whole playback
      // session. It does *not* have to be the frontmost view — putting it
      // on top of FlutterView covers the intro, letterbox and controls
      // (the "multiple pictures" mess). Sit behind Flutter instead.
      let host = PiPHostView(frame: window.bounds)
      host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      if let flutterView = window.rootViewController?.view,
        flutterView.superview === window
      {
        window.insertSubview(host, belowSubview: flutterView)
      } else {
        window.insertSubview(host, at: 0)
      }
      window.layoutIfNeeded()

      let layer = host.displayView.sampleBufferDisplayLayer
      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: layer,
        playbackDelegate: self
      )
      let pip = AVPictureInPictureController(contentSource: contentSource)
      pip.delegate = self
      pip.canStartPictureInPictureAutomaticallyFromInline = true

      hostView = host
      pipController = pip
      enabled = true
      didInvalidatePlaybackState = false

      // Do not call startPictureInPicture() from willResignActive: AVKit
      // rejects it (PGPegasus / "Failed to start picture in picture") even
      // when isPictureInPicturePossible is true. Auto-start is owned by
      // canStartPictureInPictureAutomaticallyFromInline. PiP is dismissed
      // when the app returns to the foreground (YouTube-style).
      lifecycleObservers.append(
        NotificationCenter.default.addObserver(
          forName: UIApplication.willResignActiveNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          guard let self = self, let pip = self.pipController else {
            return
          }
          self.onEvent?(
            "resignActive: possible=\(pip.isPictureInPicturePossible) active=\(pip.isPictureInPictureActive) frames=\(self.frameCount) paused=\(self.mpvIsPaused())"
          )
        }
      )
      lifecycleObservers.append(
        NotificationCenter.default.addObserver(
          forName: UIApplication.didBecomeActiveNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          guard let self = self, let pip = self.pipController else {
            return
          }
          if pip.isPictureInPictureActive {
            self.onEvent?("becomeActive: stopping PiP")
            pip.stopPictureInPicture()
          }
        }
      )
    }

    private func teardown() {
      enabled = false
      mpvHandle = nil
      didInvalidatePlaybackState = false
      for observer in lifecycleObservers {
        NotificationCenter.default.removeObserver(observer)
      }
      lifecycleObservers.removeAll()
      pipController?.stopPictureInPicture()
      pipController = nil
      displayLayer?.flushAndRemoveImage()
      hostView?.removeFromSuperview()
      hostView = nil
      cachedFormatDescription = nil
    }

    private func startWhenPossible(attemptsLeft: Int) {
      guard let pip = pipController else {
        return
      }
      if pip.isPictureInPictureActive {
        return
      }
      if pip.isPictureInPicturePossible {
        pip.startPictureInPicture()
        return
      }
      guard attemptsLeft > 0 else {
        onEvent?("gave up waiting for PiP to become possible")
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.startWhenPossible(attemptsLeft: attemptsLeft - 1)
      }
    }

    // MARK: - Frame ingestion (called from the render worker thread)

    public func enqueue(_ pixelBuffer: CVPixelBuffer) {
      guard enabled, let layer = displayLayer else {
        return
      }
      if layer.status == .failed {
        layer.flush()
      }
      guard layer.isReadyForMoreMediaData else {
        return
      }

      frameCount += 1
      let width = CVPixelBufferGetWidth(pixelBuffer)
      let height = CVPixelBufferGetHeight(pixelBuffer)
      if width != lastFrameWidth || height != lastFrameHeight {
        lastFrameWidth = width
        lastFrameHeight = height
        DispatchQueue.main.async { [weak self] in
          self?.onEvent?("frame size changed to \(width)x\(height)")
        }
      }
      if !didInvalidatePlaybackState {
        didInvalidatePlaybackState = true
        DispatchQueue.main.async { [weak self] in
          self?.pipController?.invalidatePlaybackState()
        }
      }

      var formatDescription: CMVideoFormatDescription?
      if let cached = cachedFormatDescription,
        CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: pixelBuffer)
      {
        formatDescription = cached
      } else {
        CMVideoFormatDescriptionCreateForImageBuffer(
          allocator: kCFAllocatorDefault,
          imageBuffer: pixelBuffer,
          formatDescriptionOut: &formatDescription
        )
        cachedFormatDescription = formatDescription
      }
      guard let formatDescription = formatDescription else {
        return
      }

      // Frames are displayed immediately upon arrival; mpv already paces
      // rendering, so no explicit presentation timestamps are needed.
      var timing = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
        decodeTimeStamp: .invalid
      )
      var sampleBuffer: CMSampleBuffer?
      let status = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: formatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
      )
      guard status == noErr, let sampleBuffer = sampleBuffer else {
        return
      }
      if let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: true) as? [CFMutableDictionary],
        let first = attachments.first
      {
        CFDictionarySetValue(
          first,
          Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately)
            .toOpaque(),
          Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
      }
      layer.enqueue(sampleBuffer)
    }

    // MARK: - mpv helpers

    private func mpvGetDouble(_ name: String) -> Double {
      guard let handle = mpvHandle else {
        return 0
      }
      var value: Double = 0
      mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value)
      return value
    }

    private func mpvIsPaused() -> Bool {
      guard let handle = mpvHandle else {
        return false
      }
      var paused: Int32 = 0
      mpv_get_property(handle, "pause", MPV_FORMAT_FLAG, &paused)
      return paused != 0
    }
  }

  @available(iOS 15.0, *)
  extension MediaKitPiPController: AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerWillStartPictureInPicture(
      _ pictureInPictureController: AVPictureInPictureController
    ) {
      onEvent?("willStart")
    }

    public func pictureInPictureControllerDidStartPictureInPicture(
      _ pictureInPictureController: AVPictureInPictureController
    ) {
      onEvent?("didStart")
    }

    public func pictureInPictureControllerDidStopPictureInPicture(
      _ pictureInPictureController: AVPictureInPictureController
    ) {
      onEvent?("didStop")
    }

    public func pictureInPictureController(
      _ pictureInPictureController: AVPictureInPictureController,
      failedToStartPictureInPictureWithError error: Error
    ) {
      onEvent?("failed: \(error.localizedDescription)")
    }

    public func pictureInPictureController(
      _ pictureInPictureController: AVPictureInPictureController,
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
        completionHandler: @escaping (Bool) -> Void
    ) {
      onEvent?("restore")
      completionHandler(true)
    }
  }

  @available(iOS 15.0, *)
  extension MediaKitPiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(
      _ pictureInPictureController: AVPictureInPictureController,
      setPlaying playing: Bool
    ) {
      guard let handle = mpvHandle else {
        return
      }
      mpv_set_property_string(handle, "pause", playing ? "no" : "yes")
    }

    public func pictureInPictureControllerTimeRangeForPlayback(
      _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
      let duration = mpvGetDouble("duration")
      guard duration > 0 else {
        return CMTimeRange(
          start: .negativeInfinity,
          duration: .positiveInfinity
        )
      }
      let position = mpvGetDouble("time-pos")
      let now = CMClockGetTime(CMClockGetHostTimeClock())
      let start = CMTimeSubtract(
        now, CMTime(seconds: position, preferredTimescale: 600))
      return CMTimeRange(
        start: start,
        duration: CMTime(seconds: duration, preferredTimescale: 600)
      )
    }

    public func pictureInPictureControllerIsPlaybackPaused(
      _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
      return mpvIsPaused()
    }

    public func pictureInPictureController(
      _ pictureInPictureController: AVPictureInPictureController,
      didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    public func pictureInPictureController(
      _ pictureInPictureController: AVPictureInPictureController,
      skipByInterval skipInterval: CMTime,
      completion completionHandler: @escaping () -> Void
    ) {
      if let handle = mpvHandle {
        mpv_command_string(handle, "seek \(skipInterval.seconds) relative")
      }
      completionHandler()
    }

    public func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
      _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
      return false
    }
  }
#endif
