//
//  YPVideoHelper.swift
//  YPImagePicker
//
//  Created by Sacha DSO on 27/01/2018.
//  Copyright © 2018 Yummypets. All rights reserved.
//

import AVFoundation
import CoreMotion
import UIKit

/// Abstracts Low Level AVFoudation details.
class YPVideoCaptureHelper: NSObject {
    public var isRecording: Bool { return videoOutput.isRecording }
    public var didCaptureVideo: ((URL) -> Void)?
    public var videoRecordingProgress: ((Float, TimeInterval) -> Void)?

    private let session = AVCaptureSession()
    private var timer = Timer()
    private var dateVideoStarted = Date()
    private let sessionQueue = DispatchQueue(label: "YPVideoVCSerialQueue")
    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput = AVCaptureMovieFileOutput()
    private var videoRecordingTimeLimit: TimeInterval = 0
    private var isCaptureSessionSetup: Bool = false
    private var isPreviewSetup = false
    private var previewView: UIView!
    private var motionManager = CMMotionManager()
    private var initVideoZoomFactor: CGFloat = 1.0

    static func orientationFromTransform(_ transform: CGAffineTransform) -> (orientation: UIImage.Orientation, isPortrait: Bool) {
        var assetOrientation = UIImage.Orientation.up
        var isPortrait = false
        if transform.a == 0 && transform.b == 1.0 && transform.c == -1.0 && transform.d == 0 {
            assetOrientation = .right
            isPortrait = true
        } else if transform.a == 0 && transform.b == -1.0 && transform.c == 1.0 && transform.d == 0 {
            assetOrientation = .left
            isPortrait = true
        } else if transform.a == 1.0 && transform.b == 0 && transform.c == 0 && transform.d == 1.0 {
            assetOrientation = .up
        } else if transform.a == -1.0 && transform.b == 0 && transform.c == 0 && transform.d == -1.0 {
            assetOrientation = .down
        }
        return (assetOrientation, isPortrait)
    }

    static func videoCompositionInstruction(_ track: AVCompositionTrack, asset: AVAsset) -> AVMutableVideoCompositionLayerInstruction {
        let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let assetTrack = asset.tracks(withMediaType: AVMediaType.video)[0]

        let transform = assetTrack.preferredTransform
        let assetInfo = orientationFromTransform(transform)

        var scaleToFitRatio = UIScreen.main.bounds.width / assetTrack.naturalSize.width
        if assetInfo.isPortrait {
            scaleToFitRatio = UIScreen.main.bounds.width / assetTrack.naturalSize.height
            let scaleFactor = CGAffineTransform(scaleX: scaleToFitRatio, y: scaleToFitRatio)
            instruction.setTransform(assetTrack.preferredTransform.concatenating(scaleFactor), at: CMTime.zero)
        } else {
            let scaleFactor = CGAffineTransform(scaleX: scaleToFitRatio, y: scaleToFitRatio)
            var concat = assetTrack.preferredTransform.concatenating(scaleFactor)
                .concatenating(CGAffineTransform(translationX: 0, y: UIScreen.main.bounds.width / 2))
            if assetInfo.orientation == .down {
                let fixUpsideDown = CGAffineTransform(rotationAngle: CGFloat(Double.pi))
                let windowBounds = UIScreen.main.bounds
                let yFix = assetTrack.naturalSize.height + windowBounds.height
                let centerFix = CGAffineTransform(translationX: assetTrack.naturalSize.width, y: yFix)
                concat = fixUpsideDown.concatenating(centerFix).concatenating(scaleFactor)
            }
            instruction.setTransform(concat, at: CMTime.zero)
        }

        return instruction
    }

    // MARK: - Init

    public func start(previewView: UIView, withVideoRecordingLimit: TimeInterval, completion: @escaping () -> Void) {
        self.previewView = previewView
        videoRecordingTimeLimit = withVideoRecordingLimit
        sessionQueue.async { [weak self] in
            guard let strongSelf = self else {
                return
            }
            if !strongSelf.isCaptureSessionSetup {
                strongSelf.setupCaptureSession()
            }
            strongSelf.startCamera(completion: {
                completion()
            })
        }
    }

    // MARK: - Start Camera

    public func startCamera(completion: @escaping (() -> Void)) {
        if !session.isRunning {
            sessionQueue.async { [weak self] in
                // Re-apply session preset
                self?.session.sessionPreset = .high
                let status = AVCaptureDevice.authorizationStatus(for: AVMediaType.video)
                switch status {
                case .notDetermined, .restricted, .denied:
                    self?.session.stopRunning()
                case .authorized:
                    self?.session.startRunning()
                    completion()
                    self?.tryToSetupPreview()
                @unknown default:
                    fatalError()
                }
            }
        }
    }

    // MARK: - Flip Camera

    public func flipCamera(completion: @escaping () -> Void) {
        sessionQueue.async { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.session.beginConfiguration()
            strongSelf.session.resetInputs()

            if let videoInput = strongSelf.videoInput {
                strongSelf.videoInput = flippedDeviceInputForInput(videoInput)
            }

            if let videoInput = strongSelf.videoInput {
                if strongSelf.session.canAddInput(videoInput) {
                    strongSelf.session.addInput(videoInput)
                }
            }

            // Re Add audio recording
            for device in AVCaptureDevice.devices(for: .audio) {
                if let audioInput = try? AVCaptureDeviceInput(device: device) {
                    if strongSelf.session.canAddInput(audioInput) {
                        strongSelf.session.addInput(audioInput)
                    }
                }
            }
            strongSelf.session.commitConfiguration()
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    // MARK: - Focus

    public func focus(onPoint point: CGPoint) {
        if let device = videoInput?.device {
            setFocusPointOnDevice(device: device, point: point)
        }
    }

    // MARK: - Zoom

    public func zoom(began: Bool, scale: CGFloat) {
        guard let device = videoInput?.device else {
            return
        }

        if began {
            initVideoZoomFactor = device.videoZoomFactor
            return
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            var minAvailableVideoZoomFactor: CGFloat = 1.0
            if #available(iOS 11.0, *) {
                minAvailableVideoZoomFactor = device.minAvailableVideoZoomFactor
            }
            var maxAvailableVideoZoomFactor: CGFloat = device.activeFormat.videoMaxZoomFactor
            if #available(iOS 11.0, *) {
                maxAvailableVideoZoomFactor = device.maxAvailableVideoZoomFactor
            }
            maxAvailableVideoZoomFactor = min(maxAvailableVideoZoomFactor, YPConfig.maxCameraZoomFactor)

            let desiredZoomFactor = initVideoZoomFactor * scale
            device.videoZoomFactor = max(minAvailableVideoZoomFactor, min(desiredZoomFactor, maxAvailableVideoZoomFactor))
        } catch let error {
            print("💩 \(error)")
        }
    }

    // MARK: - Stop Camera

    public func stopCamera() {
        if session.isRunning {
            sessionQueue.async { [weak self] in
                self?.session.stopRunning()
            }
        }
    }

    // MARK: - Torch

    public func hasTorch() -> Bool {
        return videoInput?.device.hasTorch ?? false
    }

    public func currentTorchMode() -> AVCaptureDevice.TorchMode {
        guard let device = videoInput?.device else {
            return .off
        }
        if !device.hasTorch {
            return .off
        }
        return device.torchMode
    }

    public func toggleTorch() {
        videoInput?.device.tryToggleTorch()
    }

    // MARK: - Recording

    public func startRecording() {
        let outputURL = YPVideoProcessor.makeVideoPathURL(temporaryFolder: true, fileName: "recordedVideoRAW")

        checkOrientation { [weak self] orientation in
            guard let strongSelf = self else {
                return
            }
            if let connection = strongSelf.videoOutput.connection(with: .video) {
                if let orientation = orientation, connection.isVideoOrientationSupported {
                    connection.videoOrientation = orientation
                }
                strongSelf.videoOutput.startRecording(to: outputURL, recordingDelegate: strongSelf)
            }
        }
    }

    public func stopRecording() {
        videoOutput.stopRecording()
    }

    // Private

    private func setupCaptureSession() {
        session.beginConfiguration()
        let aDevice = deviceForPosition(.back)
        if let d = aDevice {
            videoInput = try? AVCaptureDeviceInput(device: d)
        }

        if let videoInput = videoInput {
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            }

            // Add audio recording
            for device in AVCaptureDevice.devices(for: .audio) {
                if let audioInput = try? AVCaptureDeviceInput(device: device) {
                    if session.canAddInput(audioInput) {
                        session.addInput(audioInput)
                    }
                }
            }

            let timeScale: Int32 = 30 // FPS
            let maxDuration =
                CMTimeMakeWithSeconds(videoRecordingTimeLimit, preferredTimescale: timeScale)
            videoOutput.maxRecordedDuration = maxDuration
            videoOutput.minFreeDiskSpaceLimit = 1024 * 1024
            if YPConfig.video.fileType == .mp4 {
                videoOutput.movieFragmentInterval = .invalid // Allows audio for MP4s over 10 seconds.
            }
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
            session.sessionPreset = .high
        }
        session.commitConfiguration()
        isCaptureSessionSetup = true
    }

    // MARK: - Recording Progress

    @objc
    func tick() {
        let timeElapsed = Date().timeIntervalSince(dateVideoStarted)
        let progress: Float = Float(timeElapsed) / Float(videoRecordingTimeLimit)
        DispatchQueue.main.async {
            self.videoRecordingProgress?(progress, timeElapsed)
        }
    }

    // MARK: - Orientation

    /// This enables to get the correct orientation even when the device is locked for orientation \o/
    private func checkOrientation(completion: @escaping (_ orientation: AVCaptureVideoOrientation?) -> Void) {
        motionManager.accelerometerUpdateInterval = 5
        motionManager.startAccelerometerUpdates(to: OperationQueue()) { [weak self] data, _ in
            self?.motionManager.stopAccelerometerUpdates()
            guard let data = data else {
                completion(nil)
                return
            }
            let orientation: AVCaptureVideoOrientation = abs(data.acceleration.y) < abs(data.acceleration.x)
                ? data.acceleration.x > 0 ? .landscapeLeft : .landscapeRight
                : data.acceleration.y > 0 ? .portraitUpsideDown : .portrait
            DispatchQueue.main.async {
                completion(orientation)
            }
        }
    }

    // MARK: - Preview

    func tryToSetupPreview() {
        if !isPreviewSetup {
            setupPreview()
            isPreviewSetup = true
        }
    }

    func setupPreview() {
        let videoLayer = AVCaptureVideoPreviewLayer(session: session)
        DispatchQueue.main.async {
            videoLayer.frame = self.previewView.bounds
            videoLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
            self.previewView.layer.addSublayer(videoLayer)
        }
    }
}

extension YPVideoCaptureHelper: AVCaptureFileOutputRecordingDelegate {
    public func fileOutput(_ captureOutput: AVCaptureFileOutput,
                           didStartRecordingTo fileURL: URL,
                           from connections: [AVCaptureConnection]) {
        timer = Timer.scheduledTimer(timeInterval: 1,
                                     target: self,
                                     selector: #selector(tick),
                                     userInfo: nil,
                                     repeats: true)
        dateVideoStarted = Date()
    }

    public func fileOutput(_ captureOutput: AVCaptureFileOutput,
                           didFinishRecordingTo outputFileURL: URL,
                           from connections: [AVCaptureConnection],
                           error: Error?) {
        YPVideoProcessor.cropToSquare(filePath: outputFileURL) { [weak self] url in
            guard let _self = self, let u = url else { return }
            _self.didCaptureVideo?(u)
        }
        timer.invalidate()
    }
}
