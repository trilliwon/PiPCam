//
//  CameraViewController.swift
//  PiPCam
//
//  Created by Won on 2020/03/22.
//  Copyright © 2020 Won. All rights reserved.
//

import UIKit
import os.log

class CameraViewController: UIViewController {

    var animator: UIDynamicAnimator!

    var stickyBehavior: StickyCornersBehavior!
	var frontCameraVideoPreviewView: PreviewView!
	var backCameraVideoPreviewView: PreviewView!

	var cameraService = CameraService()
	override func viewDidLoad() {
		super.viewDidLoad()
        // Add a long press recognizer to toggle debugMode.
        let longPressGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(longPress(longPress:)))
        view.addGestureRecognizer(longPressGestureRecognizer)

		configurePrevivews()
	}

	func configurePrevivews() {
		let screenBounds = UIScreen.main.bounds
		let length = floor(0.15  * max(screenBounds.width, screenBounds.height))

		backCameraVideoPreviewView = PreviewView()
		frontCameraVideoPreviewView = PreviewView(frame: CGRect(x: 0, y: 0, width: length, height: floor(length / 0.70)))
		view.addSubview(backCameraVideoPreviewView)
		backCameraVideoPreviewView.addSubview(frontCameraVideoPreviewView)

		backCameraVideoPreviewView.frame = view.frame
		backCameraVideoPreviewView.center = view.center

		frontCameraVideoPreviewView.backgroundColor = UIColor.systemBlue

        // Create a UIDynamicAnimator.
        animator = UIDynamicAnimator(referenceView: backCameraVideoPreviewView)
        /*
         Create a StickyCornersBehavior with the itemView and a corner inset,
         then add it to the animator.
         */
        stickyBehavior = StickyCornersBehavior(item: frontCameraVideoPreviewView, cornerInset: length * 0.3)
        animator.addBehavior(stickyBehavior)

        let panGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(pan(pan:)))
        frontCameraVideoPreviewView.addGestureRecognizer(panGestureRecognizer)
	}

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        // Ensure the item stays on screen during a bounds change.
        guard let corner = stickyBehavior.currentCorner else { return }
        stickyBehavior.isEnabled = false
        let bounds = CGRect(origin: CGPoint.zero, size: size)
        stickyBehavior.updateFieldsInBounds(bounds: bounds)

        coordinator.animate(alongsideTransition: { context in
            self.frontCameraVideoPreviewView.center = self.stickyBehavior.positionForCorner(corner: corner)
        }) {  context in
            self.stickyBehavior.isEnabled = true
        }
    }

    // Touch handling.
    var offset = CGPoint.zero

    // MARK: Gesture Callbacks
    @objc func pan(pan: UIPanGestureRecognizer) {
        var location = pan.location(in: view)

        switch pan.state {
        case .began:
            // Capture the initial touch offset from the itemView's center.
            let center = frontCameraVideoPreviewView.center
            offset.x = location.x - center.x
            offset.y = location.y - center.y

            // Disable the behavior while the item is manipulated by the pan recognizer.
            stickyBehavior.isEnabled = false

        case .changed:
            // Get reference bounds.
            let referenceBounds = view.bounds
            let referenceWidth = referenceBounds.width
            let referenceHeight = referenceBounds.height

            // Get item bounds.
            let itemBounds = frontCameraVideoPreviewView.bounds
            let itemHalfWidth = itemBounds.width / 2.0
            let itemHalfHeight = itemBounds.height / 2.0

            // Apply the initial offset.
            location.x -= offset.x
            location.y -= offset.y

            // Bound the item position inside the reference view.
            location.x = max(itemHalfWidth, location.x)
            location.x = min(referenceWidth - itemHalfWidth, location.x)
            location.y = max(itemHalfHeight, location.y)
            location.y = min(referenceHeight - itemHalfHeight, location.y)

            // Apply the resulting item center.
            frontCameraVideoPreviewView.center = location

        case .cancelled, .ended:
            // Get the current velocity of the item from the pan gesture recognizer.
            let velocity = pan.velocity(in: view)

            // Re-enable the stickyCornersBehavior.
            stickyBehavior.isEnabled = true

            // Add the current velocity to the sticky corners behavior.
            stickyBehavior.addLinearVelocity(velocity: velocity)

        default: ()
        }
    }

    @objc func longPress(longPress: UILongPressGestureRecognizer) {
        guard longPress.state == .began else { return }
		animator.setValue(true, forKey: "debugEnabled")
    }
}

private enum SessionSetupResult {
	case success
	case notAuthorized
	case configurationFailed
	case multiCamNotSupported
}

import AVFoundation

class CameraService: NSObject {
	private let session = AVCaptureMultiCamSession()

	/// Communicate with the session and other session objects on this queue.
	private let sessionQueue = DispatchQueue(label: "com.trilliwon.pipcam.session-queue")
	private let dataOutputQueue = DispatchQueue(label: "com.trilliwon.pipcam.data-output-queue")


	private var isSessionRunning = false
	@objc dynamic private(set) var backCameraDeviceInput: AVCaptureDeviceInput?

	private var setupResult: SessionSetupResult = .success

	private let backCameraVideoDataOutput = AVCaptureVideoDataOutput()
	private let frontCameraVideoDataOutput = AVCaptureVideoDataOutput()

	private var frontCameraDeviceInput: AVCaptureDeviceInput?
	private var microphoneDeviceInput: AVCaptureDeviceInput?

	private let backMicrophoneAudioDataOutput = AVCaptureAudioDataOutput()
	private let frontMicrophoneAudioDataOutput = AVCaptureAudioDataOutput()

	weak var backCameraVideoPreviewLayer: AVCaptureVideoPreviewLayer?
	weak var frontCameraVideoPreviewLayer: AVCaptureVideoPreviewLayer?

	init(frontPreviewLayer: AVCaptureVideoPreviewLayer, backPreviewLayer: AVCaptureVideoPreviewLayer) {
		backCameraVideoPreviewLayer = backPreviewLayer
		frontCameraVideoPreviewLayer = frontPreviewLayer
		super.init()
	}

	override init() {
		super.init()

		backCameraVideoPreviewLayer?.setSessionWithNoConnection(session)
		frontCameraVideoPreviewLayer?.setSessionWithNoConnection(session)
		UIDevice.current.beginGeneratingDeviceOrientationNotifications()

		/*
		Configure the capture session.
		In general it is not safe to mutate an AVCaptureSession or any of its
		inputs, outputs, or connections from multiple threads at the same time.

		Don't do this on the main queue, because AVCaptureMultiCamSession.startRunning()
		is a blocking call, which can take a long time. Dispatch session setup
		to the sessionQueue so as not to block the main queue, which keeps the UI responsive.
		*/
		sessionQueue.async {
			self.configureSession()
		}
	}

	// MARK: KVO and Notifications

	private var sessionRunningContext = 0
	private var keyValueObservations = [NSKeyValueObservation]()

	private func addObservers() {
		let keyValueObservation = session.observe(\.isRunning, options: .new) { _, change in
			guard let isSessionRunning = change.newValue else { return }
			DispatchQueue.main.async {
//				self.recordButton.isEnabled = isSessionRunning
			}
		}
		keyValueObservations.append(keyValueObservation)

		let systemPressureStateObservation = observe(\.self.backCameraDeviceInput?.device.systemPressureState, options: .new) { _, change in
			guard let systemPressureState = change.newValue as? AVCaptureDevice.SystemPressureState else { return }
//			self.setRecommendedFrameRateRangeForPressureState(systemPressureState)
		}
		keyValueObservations.append(systemPressureStateObservation)

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(didEnterBackground),
			name: UIApplication.didEnterBackgroundNotification,
			object: nil
		)

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(willEnterForground),
			name: UIApplication.willEnterForegroundNotification,
			object: nil
		)

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(sessionRuntimeError),
			name: .AVCaptureSessionRuntimeError,
			object: session
		)

		// A session can run only when the app is full screen. It will be interrupted in a multi-app layout.
		// Add observers to handle these session interruptions and inform the user.
		// See AVCaptureSessionWasInterruptedNotification for other interruption reasons.
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(sessionWasInterrupted),
			name: .AVCaptureSessionWasInterrupted,
			object: session
		)

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(sessionInterruptionEnded),
			name: .AVCaptureSessionInterruptionEnded,
			object: session
		)
	}

	@objc
	func didEnterBackground(notification: Notification) {

	}

	@objc
	func willEnterForground(notification: Notification) {

	}

	@objc // Expose to Objective-C for use with #selector()
	private func sessionRuntimeError(notification: NSNotification) {
		guard let errorValue = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else {
			return
		}

		let error = AVError(_nsError: errorValue)
		os_log("Capture session runtime error: %@", error.localizedDescription)

		/*
		Automatically try to restart the session running if media services were
		reset and the last start running succeeded. Otherwise, enable the user
		to try to resume the session running.
		*/
		if error.code == .mediaServicesWereReset {
			sessionQueue.async {
				if self.isSessionRunning {
					self.session.startRunning()
					self.isSessionRunning = self.session.isRunning
				} else {
					DispatchQueue.main.async {
//						self.resumeButton.isHidden = false
					}
				}
			}
		} else {
//			resumeButton.isHidden = false
		}
	}

	@objc // Expose to Objective-C for use with #selector()
	private func sessionWasInterrupted(notification: NSNotification) {
		// In iOS 9 and later, the userInfo dictionary contains information on why the session was interrupted.
		if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
			let reasonIntegerValue = userInfoValue.integerValue,
			let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
			print("Capture session was interrupted (\(reason))")

			if reason == .videoDeviceInUseByAnotherClient {
				// Simply fade-in a button to enable the user to try to resume the session running.
//				resumeButton.isHidden = false
//				resumeButton.alpha = 0.0
//				UIView.animate(withDuration: 0.25) {
//					self.resumeButton.alpha = 1.0
//				}
			} else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
				// Simply fade-in a label to inform the user that the camera is unavailable.
//				cameraUnavailableLabel.isHidden = false
//				cameraUnavailableLabel.alpha = 0.0
//				UIView.animate(withDuration: 0.25) {
//					self.cameraUnavailableLabel.alpha = 1.0
//				}
			}
		}
	}

	@objc // Expose to Objective-C for use with #selector()
	private func sessionInterruptionEnded(notification: NSNotification) {
//		if !resumeButton.isHidden {
//			UIView.animate(withDuration: 0.25,
//						   animations: {
//							self.resumeButton.alpha = 0
//			}, completion: { _ in
//				self.resumeButton.isHidden = true
//			})
//		}
//		if !cameraUnavailableLabel.isHidden {
//			UIView.animate(withDuration: 0.25,
//						   animations: {
//							self.cameraUnavailableLabel.alpha = 0
//			}, completion: { _ in
//				self.cameraUnavailableLabel.isHidden = true
//			})
//		}
	}

	private func removeObservers() {
		for keyValueObservation in keyValueObservations {
			keyValueObservation.invalidate()
		}

		keyValueObservations.removeAll()
	}



	func startSession() {
		sessionQueue.async {
			switch self.setupResult {
			case .success:
				// Only setup observers and start the session running if setup succeeded.
				self.addObservers()
				self.session.startRunning()
				self.isSessionRunning = self.session.isRunning

			case .notAuthorized:
				DispatchQueue.main.async {
				// TODO: - send notification
				}

			case .configurationFailed:
				DispatchQueue.main.async {
				// TODO: - send notification
				}

			case .multiCamNotSupported:
				DispatchQueue.main.async {
				// TODO: - send notification
				}
			}
		}
	}

	/// Must be called on the session queue
	private func configureSession() {
		guard setupResult == .success else { return }

		guard AVCaptureMultiCamSession.isMultiCamSupported else {
			print("MultiCam not supported on this device")
			setupResult = .multiCamNotSupported
			return
		}

		// When using AVCaptureMultiCamSession, it is best to manually add connections from AVCaptureInputs to AVCaptureOutputs
		session.beginConfiguration()
		defer {
			session.commitConfiguration()
			if setupResult == .success {
//				checkSystemCost()
			}
		}

		guard configureBackCamera() else {
			setupResult = .configurationFailed
			return
		}

		guard configureFrontCamera() else {
			setupResult = .configurationFailed
			return
		}

		guard configureMicrophone() else {
			setupResult = .configurationFailed
			return
		}
	}

	private func configureBackCamera() -> Bool {
		session.beginConfiguration()
		defer {
			session.commitConfiguration()
		}

		/// Find the back camera
		guard let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
			os_log("Could not find the back camera")
			return false
		}

		/// Add the back camera input to the session
		do {
			backCameraDeviceInput = try AVCaptureDeviceInput(device: backCamera)

			guard let backCameraDeviceInput = backCameraDeviceInput,
				session.canAddInput(backCameraDeviceInput) else {
					os_log("Could not add back camera device input")
					return false
			}
			session.addInputWithNoConnections(backCameraDeviceInput)
		} catch {
			os_log("Could not create back camera device input: %@", error.localizedDescription)
			return false
		}

		/// Find the back camera device input's video port
		guard
			let backCameraVideoPort = backCameraDeviceInput?.ports(
				for: .video,
				sourceDeviceType: backCamera.deviceType,
				sourceDevicePosition: backCamera.position
			).first else {
				os_log("Could not find the back camera device input's video port")
				return false
		}

		/// Add the back camera video data output
		guard session.canAddOutput(backCameraVideoDataOutput) else {
			os_log("Could not add the back camera video data output")
			return false
		}
		session.addOutputWithNoConnections(backCameraVideoDataOutput)
		backCameraVideoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
		backCameraVideoDataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)

		/// Connect the back camera device input to the back camera video data output
		let backCameraVideoDataOutputConnection = AVCaptureConnection(inputPorts: [backCameraVideoPort], output: backCameraVideoDataOutput)
		guard session.canAddConnection(backCameraVideoDataOutputConnection) else {
			os_log("Could not add a connection to the back camera video data output")
			return false
		}
		session.addConnection(backCameraVideoDataOutputConnection)
		backCameraVideoDataOutputConnection.videoOrientation = .portrait

		/// Connect the back camera device input to the back camera video preview layer
		guard let backCameraVideoPreviewLayer = backCameraVideoPreviewLayer else {
			return false
		}
		let backCameraVideoPreviewLayerConnection = AVCaptureConnection(inputPort: backCameraVideoPort, videoPreviewLayer: backCameraVideoPreviewLayer)
		guard session.canAddConnection(backCameraVideoPreviewLayerConnection) else {
			os_log("Could not add a connection to the back camera video preview layer")
			return false
		}
		session.addConnection(backCameraVideoPreviewLayerConnection)
		return true
	}

	private func configureFrontCamera() -> Bool {
		session.beginConfiguration()
		defer {
			session.commitConfiguration()
		}

		/// Find the front camera
		guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
			os_log("Could not find the front camera")
			return false
		}

		/// Add the front camera input to the session
		do {
			frontCameraDeviceInput = try AVCaptureDeviceInput(device: frontCamera)
			guard let frontCameraDeviceInput = frontCameraDeviceInput,
				session.canAddInput(frontCameraDeviceInput) else {
					os_log("Could not add front camera device input")
					return false
			}
			session.addInputWithNoConnections(frontCameraDeviceInput)
		} catch {
			os_log("Could not create front camera device input: %@", error.localizedDescription)
			return false
		}

		/// Find the front camera device input's video port
		guard
			let frontCameraVideoPort = frontCameraDeviceInput?.ports(
				for: .video,
				sourceDeviceType: frontCamera.deviceType,
				sourceDevicePosition: frontCamera.position).first else {
					os_log("Could not find the front camera device input's video port")
					return false
		}

		/// Add the front camera video data output
		guard session.canAddOutput(frontCameraVideoDataOutput) else {
			os_log("Could not add the front camera video data output")
			return false
		}
		session.addOutputWithNoConnections(frontCameraVideoDataOutput)
		frontCameraVideoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
		frontCameraVideoDataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)

		/// Connect the front camera device input to the front camera video data output
		let frontCameraVideoDataOutputConnection = AVCaptureConnection(inputPorts: [frontCameraVideoPort], output: frontCameraVideoDataOutput)
		guard session.canAddConnection(frontCameraVideoDataOutputConnection) else {
			os_log("Could not add a connection to the front camera video data output")
			return false
		}
		session.addConnection(frontCameraVideoDataOutputConnection)
		frontCameraVideoDataOutputConnection.videoOrientation = .portrait
		frontCameraVideoDataOutputConnection.automaticallyAdjustsVideoMirroring = false
		frontCameraVideoDataOutputConnection.isVideoMirrored = true

		/// Connect the front camera device input to the front camera video preview layer
		guard let frontCameraVideoPreviewLayer = frontCameraVideoPreviewLayer else {
			return false
		}
		let frontCameraVideoPreviewLayerConnection = AVCaptureConnection(inputPort: frontCameraVideoPort, videoPreviewLayer: frontCameraVideoPreviewLayer)
		guard session.canAddConnection(frontCameraVideoPreviewLayerConnection) else {
			os_log("Could not add a connection to the front camera video preview layer")
			return false
		}
		session.addConnection(frontCameraVideoPreviewLayerConnection)
		frontCameraVideoPreviewLayerConnection.automaticallyAdjustsVideoMirroring = false
		frontCameraVideoPreviewLayerConnection.isVideoMirrored = true
		return true
	}

	private func configureMicrophone() -> Bool {
		session.beginConfiguration()
		defer {
			session.commitConfiguration()
		}

		/// Find the microphone
		guard let microphone = AVCaptureDevice.default(for: .audio) else {
			os_log("Could not find the microphone")
			return false
		}

		/// Add the microphone input to the session
		do {
			microphoneDeviceInput = try AVCaptureDeviceInput(device: microphone)

			guard let microphoneDeviceInput = microphoneDeviceInput,
				session.canAddInput(microphoneDeviceInput) else {
					os_log("Could not add microphone device input")
					return false
			}
			session.addInputWithNoConnections(microphoneDeviceInput)
		} catch {
			os_log("Could not create microphone input: %@", error.localizedDescription)
			return false
		}

		/// Find the audio device input's back audio port
		guard
			let backMicrophonePort = microphoneDeviceInput?.ports(
				for: .audio,
				sourceDeviceType: microphone.deviceType,
				sourceDevicePosition: .back).first else {
					os_log("Could not find the back camera device input's audio port")
					return false
		}

		/// Find the audio device input's front audio port
		guard
			let frontMicrophonePort = microphoneDeviceInput?.ports(
				for: .audio,
				sourceDeviceType: microphone.deviceType,
				sourceDevicePosition: .front).first else {
					os_log("Could not find the front camera device input's audio port")
			return false
		}

		/// Add the back microphone audio data output
		guard session.canAddOutput(backMicrophoneAudioDataOutput) else {
			os_log("Could not add the back microphone audio data output")
			return false
		}
		session.addOutputWithNoConnections(backMicrophoneAudioDataOutput)
		backMicrophoneAudioDataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)

		/// Add the front microphone audio data output
		guard session.canAddOutput(frontMicrophoneAudioDataOutput) else {
			os_log("Could not add the front microphone audio data output")
			return false
		}
		session.addOutputWithNoConnections(frontMicrophoneAudioDataOutput)
		frontMicrophoneAudioDataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)

		/// Connect the back microphone to the back audio data output
		let backMicrophoneAudioDataOutputConnection = AVCaptureConnection(inputPorts: [backMicrophonePort], output: backMicrophoneAudioDataOutput)
		guard session.canAddConnection(backMicrophoneAudioDataOutputConnection) else {
			os_log("Could not add a connection to the back microphone audio data output")
			return false
		}
		session.addConnection(backMicrophoneAudioDataOutputConnection)

		/// Connect the front microphone to the back audio data output
		let frontMicrophoneAudioDataOutputConnection = AVCaptureConnection(inputPorts: [frontMicrophonePort], output: frontMicrophoneAudioDataOutput)
		guard session.canAddConnection(frontMicrophoneAudioDataOutputConnection) else {
			os_log("Could not add a connection to the front microphone audio data output")
			return false
		}
		session.addConnection(frontMicrophoneAudioDataOutputConnection)
		return true
	}

	// MARK: - Session Cost Check

	struct ExceededCaptureSessionCosts: OptionSet {
		let rawValue: Int

		static let systemPressureCost = ExceededCaptureSessionCosts(rawValue: 1 << 0)
		static let hardwareCost = ExceededCaptureSessionCosts(rawValue: 1 << 1)
	}

	func checkSystemCost() {
		var exceededSessionCosts: ExceededCaptureSessionCosts = []

		if session.systemPressureCost > 1.0 {
			exceededSessionCosts.insert(.systemPressureCost)
		}

		if session.hardwareCost > 1.0 {
			exceededSessionCosts.insert(.hardwareCost)
		}

		switch exceededSessionCosts {

		case .systemPressureCost:
			// Choice #1: Reduce front camera resolution
			if reduceResolutionForCamera(.front) {
				checkSystemCost()
			}

			// Choice 2: Reduce the number of video input ports
			else if reduceVideoInputPorts() {
				checkSystemCost()
			}

			// Choice #3: Reduce back camera resolution
			else if reduceResolutionForCamera(.back) {
				checkSystemCost()
			}

			// Choice #4: Reduce front camera frame rate
			else if reduceFrameRateForCamera(.front) {
				checkSystemCost()
			}

			// Choice #5: Reduce frame rate of back camera
			else if reduceFrameRateForCamera(.back) {
				checkSystemCost()
			} else {
				os_log("Unable to further reduce session cost.")
			}

		case .hardwareCost:
			// Choice #1: Reduce front camera resolution
			if reduceResolutionForCamera(.front) {
				checkSystemCost()
			}

			// Choice 2: Reduce back camera resolution
			else if reduceResolutionForCamera(.back) {
				checkSystemCost()
			}

			// Choice #3: Reduce front camera frame rate
			else if reduceFrameRateForCamera(.front) {
				checkSystemCost()
			}

			// Choice #4: Reduce back camera frame rate
			else if reduceFrameRateForCamera(.back) {
				checkSystemCost()
			} else {
				os_log("Unable to further reduce session cost.")
			}

		case [.systemPressureCost, .hardwareCost]:
			// Choice #1: Reduce front camera resolution
			if reduceResolutionForCamera(.front) {
				checkSystemCost()
			}

			// Choice #2: Reduce back camera resolution
			else if reduceResolutionForCamera(.back) {
				checkSystemCost()
			}

			// Choice #3: Reduce front camera frame rate
			else if reduceFrameRateForCamera(.front) {
				checkSystemCost()
			}

			// Choice #4: Reduce back camera frame rate
			else if reduceFrameRateForCamera(.back) {
				checkSystemCost()
			} else {
				os_log("Unable to further reduce session cost.")
			}

		default:
			break
		}
	}

	func reduceResolutionForCamera(_ position: AVCaptureDevice.Position) -> Bool {
		for connection in session.connections {
			for inputPort in connection.inputPorts {
				if inputPort.mediaType == .video && inputPort.sourceDevicePosition == position {
					guard let videoDeviceInput: AVCaptureDeviceInput = inputPort.input as? AVCaptureDeviceInput else {
						return false
					}

					var dims: CMVideoDimensions

					var width: Int32
					var height: Int32
					var activeWidth: Int32
					var activeHeight: Int32

					dims = CMVideoFormatDescriptionGetDimensions(videoDeviceInput.device.activeFormat.formatDescription)
					activeWidth = dims.width
					activeHeight = dims.height

					if ( activeHeight <= 480 ) && ( activeWidth <= 640 ) {
						return false
					}

					let formats = videoDeviceInput.device.formats
					if let formatIndex = formats.firstIndex(of: videoDeviceInput.device.activeFormat) {

						for index in (0..<formatIndex).reversed() {
							let format = videoDeviceInput.device.formats[index]
							if format.isMultiCamSupported {
								dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
								width = dims.width
								height = dims.height

								if width < activeWidth || height < activeHeight {
									do {
										try videoDeviceInput.device.lockForConfiguration()
										videoDeviceInput.device.activeFormat = format

										videoDeviceInput.device.unlockForConfiguration()

										print("reduced width = \(width), reduced height = \(height)")

										return true
									} catch {
										print("Could not lock device for configuration: \(error)")

										return false
									}

								} else {
									continue
								}
							}
						}
					}
				}
			}
		}

		return false
	}

	func reduceFrameRateForCamera(_ position: AVCaptureDevice.Position) -> Bool {
		for connection in session.connections {
			for inputPort in connection.inputPorts {

				if inputPort.mediaType == .video && inputPort.sourceDevicePosition == position {
					guard let videoDeviceInput: AVCaptureDeviceInput = inputPort.input as? AVCaptureDeviceInput else {
						return false
					}
					let activeMinFrameDuration = videoDeviceInput.device.activeVideoMinFrameDuration
					var activeMaxFrameRate: Double = Double(activeMinFrameDuration.timescale) / Double(activeMinFrameDuration.value)
					activeMaxFrameRate -= 10.0

					// Cap the device frame rate to this new max, never allowing it to go below 15 fps
					if activeMaxFrameRate >= 15.0 {
						do {
							try videoDeviceInput.device.lockForConfiguration()
							videoDeviceInput.videoMinFrameDurationOverride = CMTimeMake(value: 1, timescale: Int32(activeMaxFrameRate))

							videoDeviceInput.device.unlockForConfiguration()

							print("reduced fps = \(activeMaxFrameRate)")

							return true
						} catch {
							print("Could not lock device for configuration: \(error)")
							return false
						}
					} else {
						return false
					}
				}
			}
		}

		return false
	}

	func reduceVideoInputPorts () -> Bool {
		var newConnection: AVCaptureConnection
		var result = false

		for connection in session.connections {
			for inputPort in connection.inputPorts where inputPort.sourceDeviceType == .builtInDualCamera {
				print("Changing input from dual to single camera")

				guard let videoDeviceInput: AVCaptureDeviceInput = inputPort.input as? AVCaptureDeviceInput,
					let wideCameraPort: AVCaptureInput.Port = videoDeviceInput.ports(for: .video,
																					 sourceDeviceType: .builtInWideAngleCamera,
																					 sourceDevicePosition: videoDeviceInput.device.position).first else {
																						return false
				}

				if let previewLayer = connection.videoPreviewLayer {
					newConnection = AVCaptureConnection(inputPort: wideCameraPort, videoPreviewLayer: previewLayer)
				} else if let savedOutput = connection.output {
					newConnection = AVCaptureConnection(inputPorts: [wideCameraPort], output: savedOutput)
				} else {
					continue
				}
				session.beginConfiguration()

				session.removeConnection(connection)

				if session.canAddConnection(newConnection) {
					session.addConnection(newConnection)

					session.commitConfiguration()
					result = true
				} else {
					print("Could not add new connection to the session")
					session.commitConfiguration()
					return false
				}
			}
		}
		return result
	}

	private func setRecommendedFrameRateRangeForPressureState(_ systemPressureState: AVCaptureDevice.SystemPressureState) {
		// The frame rates used here are for demonstrative purposes only for this app.
		// Your frame rate throttling may be different depending on your app's camera configuration.
		let pressureLevel = systemPressureState.level
		if pressureLevel == .serious || pressureLevel == .critical {
//			if self.movieRecorder == nil || self.movieRecorder?.isRecording == false {
//				do {
//					try self.backCameraDeviceInput?.device.lockForConfiguration()
//
//					print("WARNING: Reached elevated system pressure level: \(pressureLevel). Throttling frame rate.")
//
//					self.backCameraDeviceInput?.device.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: 20 )
//					self.backCameraDeviceInput?.device.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: 15 )
//
//					self.backCameraDeviceInput?.device.unlockForConfiguration()
//				} catch {
//					print("Could not lock device for configuration: \(error)")
//				}
//			}
		} else if pressureLevel == .shutdown {
			print("Session stopped running due to system pressure level.")
		}
	}
}

extension CameraService: AVCaptureAudioDataOutputSampleBufferDelegate {

}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {

	func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {

	}
}
