//
//  PreviewView.swift
//  ARText
//
//  Created by Jack Paschke on 3/21/22.
//

import UIKit
import AVFoundation

class PreviewView: UIView {
	var videoPreviewLayer: AVCaptureVideoPreviewLayer {
		guard let layer = layer as? AVCaptureVideoPreviewLayer else {
			fatalError("AVCapture error")
		}
		return layer
	}
	
	var session: AVCaptureSession? {
		get {
			return videoPreviewLayer.session
		}
		set {
			videoPreviewLayer.session = newValue
		}
	}
	override class var layerClass: AnyClass {
		return AVCaptureVideoPreviewLayer.self
	}
}
