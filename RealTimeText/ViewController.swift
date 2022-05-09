//
//  ViewController.swift
//  ARText
//
//  Created by Jack Paschke on 3/21/22.
//

import UIKit
import AVFoundation
import Vision

class ViewController: UIViewController {
	@IBOutlet weak var previewView: PreviewView!
	@IBOutlet weak var cutoutView: UIView!
    @IBOutlet weak var textView: UITextView!
    @IBOutlet weak var textSlider: UISlider!
    @IBOutlet weak var textSelector: UIBarButtonItem!
    
    var maskLayer = CAShapeLayer()

	var currentOrientation = UIDeviceOrientation.portrait
	
	private let captureSession = AVCaptureSession()
    let captureSessionQueue = DispatchQueue(label: "csQueue")
    
	var captureDevice: AVCaptureDevice?
    
	var videoDataOutput = AVCaptureVideoDataOutput()
    let videoDataOutputQueue = DispatchQueue(label: "vopQueue")

	var regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)

	var textOrientation = CGImagePropertyOrientation.up
	
	var bufferAspectRatio: Double!

	var uiRotationTransform = CGAffineTransform.identity

	var bottomToTopTransform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -1)

	var roiToGlobalTransform = CGAffineTransform.identity
	
	var visionToAVFTransform = CGAffineTransform.identity
	
	
	override func viewDidLoad() {
		super.viewDidLoad()
		previewView.session = captureSession
		
		cutoutView.backgroundColor = UIColor.gray.withAlphaComponent(0.5)
		maskLayer.backgroundColor = UIColor.clear.cgColor
		maskLayer.fillRule = .evenOdd
		cutoutView.layer.mask = maskLayer
		
        captureSessionQueue.async {
            self.setupCamera()
            
            DispatchQueue.main.async {
                self.calcROI()
            }
        }
	}
	
	override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
		super.viewWillTransition(to: size, with: coordinator)

		let deviceOrientation = UIDevice.current.orientation
		if deviceOrientation.isPortrait || deviceOrientation.isLandscape {
			currentOrientation = deviceOrientation
		}
		
		if let videoPreviewLayerConnection = previewView.videoPreviewLayer.connection {
			if let newVideoOrientation = AVCaptureVideoOrientation(deviceOrientation: deviceOrientation) {
				videoPreviewLayerConnection.videoOrientation = newVideoOrientation
			}
		}
		
		calcROI()
	}
	
	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		updateCutout()
	}
	
	
	func calcROI() {

        let heightRat = 0.75
        let widthRat = 1.0
        let maxWidth = 1.0
		
		let size: CGSize
		if currentOrientation.isPortrait || currentOrientation == .unknown {
			size = CGSize(width: min(widthRat * bufferAspectRatio, maxWidth), height: heightRat / bufferAspectRatio)
		} else {
			size = CGSize(width: widthRat, height: heightRat)
		}
		// Center ROI
		regionOfInterest.origin = CGPoint(x: (1 - size.width) / 2, y: (1 - size.height))
		regionOfInterest.size = size
		setupOrientationAndTransform()
		
		// Modify cutout
		DispatchQueue.main.async {
			self.updateCutout()
		}
	}
	
	func updateCutout() {
		let roiRectTransform = bottomToTopTransform.concatenating(uiRotationTransform)
		let cutout = previewView.videoPreviewLayer.layerRectConverted(fromMetadataOutputRect: regionOfInterest.applying(roiRectTransform))
		
		// Create the mask.
		let path = UIBezierPath(rect: cutoutView.frame)
		path.append(UIBezierPath(rect: cutout))
		maskLayer.path = path.cgPath
		
		// Place view under cutout
        var textFrame = cutout
        textFrame.origin.y += textFrame.size.height
        textView.frame = textFrame
	}
	
	func setupOrientationAndTransform() {

		let roi = regionOfInterest
		roiToGlobalTransform = CGAffineTransform(translationX: roi.origin.x, y: roi.origin.y).scaledBy(x: roi.width, y: roi.height)
		
		switch currentOrientation {
		case .landscapeLeft:
			textOrientation = CGImagePropertyOrientation.up
			uiRotationTransform = CGAffineTransform.identity
		case .landscapeRight:
			textOrientation = CGImagePropertyOrientation.down
			uiRotationTransform = CGAffineTransform(translationX: 1, y: 1).rotated(by: CGFloat.pi)
		case .portraitUpsideDown:
			textOrientation = CGImagePropertyOrientation.left
			uiRotationTransform = CGAffineTransform(translationX: 1, y: 0).rotated(by: CGFloat.pi / 2)
		default:
			textOrientation = CGImagePropertyOrientation.right
			uiRotationTransform = CGAffineTransform(translationX: 0, y: 1).rotated(by: -CGFloat.pi / 2)
		}
		
		// Full Vision ROI to AVF transform.
		visionToAVFTransform = roiToGlobalTransform.concatenating(bottomToTopTransform).concatenating(uiRotationTransform)
	}
	
	func setupCamera() {
		guard let captureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: AVMediaType.video, position: .back) else {
			print("Could not create capture device.")
			return
		}
		self.captureDevice = captureDevice
		
		if captureDevice.supportsSessionPreset(.hd4K3840x2160) {
			captureSession.sessionPreset = AVCaptureSession.Preset.hd4K3840x2160
			bufferAspectRatio = 3840.0 / 2160.0
		} else {
			captureSession.sessionPreset = AVCaptureSession.Preset.hd1920x1080
			bufferAspectRatio = 1920.0 / 1080.0
		}
		
		guard let deviceInput = try? AVCaptureDeviceInput(device: captureDevice) else {
			print("Could not create device input.")
			return
		}
		if captureSession.canAddInput(deviceInput) {
			captureSession.addInput(deviceInput)
		}
		
		// Configure video data output.
		videoDataOutput.alwaysDiscardsLateVideoFrames = true
		videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
		videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
		if captureSession.canAddOutput(videoDataOutput) {
			captureSession.addOutput(videoDataOutput)

            videoDataOutput.connection(with: AVMediaType.video)?.preferredVideoStabilizationMode = .auto
            
		} else {
			print("Could not add VDO output")
			return
		}
		
		// Set zoom and autofocus to help focus on very small text.
		do {
			try captureDevice.lockForConfiguration()
			captureDevice.videoZoomFactor = 2
			captureDevice.autoFocusRangeRestriction = .near
			captureDevice.unlockForConfiguration()
		} catch {
			print("Could not set zoom level due to error: \(error)")
			return
		}
		
		captureSession.startRunning()
	}
	
	func showString(string: String) {
		captureSessionQueue.sync {
            DispatchQueue.main.async {
                let formattedString = string.decomposedStringWithCanonicalMapping
                print("input string", formattedString)
                self.textView.text = formattedString

                
                self.textView.isHidden = false
            }
		}
	}

    
	@IBAction func handleTap(_ sender: UITapGestureRecognizer) {
        captureSessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            else{
                self.captureSession.startRunning()
            }
            DispatchQueue.main.async {
                self.textView.isHidden = true
            }
        }
	}
}

extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
	
	func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
	}
}

extension AVCaptureVideoOrientation {
	init?(deviceOrientation: UIDeviceOrientation) {
		switch deviceOrientation {
		case .portrait: self = .portrait
		case .portraitUpsideDown: self = .portraitUpsideDown
		case .landscapeLeft: self = .landscapeRight
		case .landscapeRight: self = .landscapeLeft
		default: return nil
		}
	}
}
