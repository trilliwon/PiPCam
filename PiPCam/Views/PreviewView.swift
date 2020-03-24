//
//  PreviewView.swift
//  PiPCam
//
//  Created by Won on 2020/03/23.
//  Copyright © 2020 Won. All rights reserved.
//

import UIKit
import AVFoundation

class PreviewView: UIView {
	var videoPreviewLayer: AVCaptureVideoPreviewLayer {
		guard let layer = layer as? AVCaptureVideoPreviewLayer else {
			fatalError("Expected `AVCaptureVideoPreviewLayer` type for layer. Check PreviewView.layerClass implementation.")
		}

		return layer
	}

	override class var layerClass: AnyClass {
		return AVCaptureVideoPreviewLayer.self
	}
}
