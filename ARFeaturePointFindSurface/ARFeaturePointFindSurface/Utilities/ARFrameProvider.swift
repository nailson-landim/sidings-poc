//
//  ARFrameProvider.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 8/27/25.
//

import ARKit

public protocol ARFrameProvider {
    
    var isRunning: Bool { get }
    var videoFormat: ARConfiguration.VideoFormat! { get }
    
    func resume()
    func pause()
    
    var currentFrame: ARFrame? { get }
    var imageResolution: CGSize { get }
    
    var sessionAnchorAdded: ((ARSession, [ARAnchor]) -> Void)? { get set }
    var sessionAnchorUpdated: ((ARSession, [ARAnchor]) -> Void)? { get set }
    var sessionAnchorRemoved: ((ARSession, [ARAnchor]) -> Void)? { get set }
}

public class ARPreviewFrameProvider: NSObject, ARFrameProvider {
    public var isRunning: Bool = false
    
    public var videoFormat: ARConfiguration.VideoFormat!
    
    public func resume() {
        
    }
    
    public func pause() {
        
    }
    
    public var currentFrame: ARFrame? = nil
    
    public var imageResolution: CGSize = .zero
    
    public var sessionAnchorAdded: ((ARSession, [ARAnchor]) -> Void)?
    
    public var sessionAnchorUpdated: ((ARSession, [ARAnchor]) -> Void)?
    
    public var sessionAnchorRemoved: ((ARSession, [ARAnchor]) -> Void)?
}

public class ARWorldTrackingFrameProvider: NSObject, ARFrameProvider, ARSessionDelegate {
    
    let session = ARSession()
    public private(set) var isRunning: Bool = false
    public private(set) var videoFormat: ARConfiguration.VideoFormat!
    
    public static var supportedVideoFormats: [ARConfiguration.VideoFormat] {
        ARWorldTrackingConfiguration.supportedVideoFormats
    }
    
    public override convenience init() {
        self.init(Self.supportedVideoFormats[0]) // assumes the first format is the preferred one
    }
    
    public init(_ videoFormat: ARConfiguration.VideoFormat) {
        super.init()
        session.delegate = self
        self.videoFormat = videoFormat
        resume()
    }
    
    public func resume() {
        guard !self.isRunning else { return }

        // Scene depth requires LiDAR. Request it only where supported so non-LiDAR devices
        // still run the session (the app only consumes rawFeaturePoints, never the depth map).
        let frameSemantics: ARConfiguration.FrameSemantics = [.sceneDepth, .smoothedSceneDepth]
        let supportsFrameSemantics = ARWorldTrackingConfiguration.supportsFrameSemantics(frameSemantics)

        let runOptions: ARSession.RunOptions = [.resetTracking,
                                                .removeExistingAnchors,
                                                .resetSceneReconstruction]
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = []
        config.isLightEstimationEnabled = true
        config.frameSemantics = supportsFrameSemantics ? frameSemantics : []
        config.isAutoFocusEnabled = true
        config.videoFormat = self.videoFormat
        self.session.run(config, options: runOptions)
        
        UIApplication.shared.isIdleTimerDisabled = true // prevent the display from sleeping automatically
        self.isRunning = true
    }
    
    public func pause() {
        guard self.isRunning else { return }
        self.session.pause()
        self.isRunning = false
    }
    
    public var currentFrame: ARFrame? {
        self.session.currentFrame
    }
    
    public var imageResolution: CGSize {
        self.videoFormat.imageResolution
    }
    
    public var sessionAnchorAdded: ((ARSession, [ARAnchor]) -> Void)? = nil
    public var sessionAnchorUpdated: ((ARSession, [ARAnchor]) -> Void)? = nil
    public var sessionAnchorRemoved: ((ARSession, [ARAnchor]) -> Void)? = nil
    
    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        sessionAnchorAdded?(session, anchors)
    }
    
    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        sessionAnchorUpdated?(session, anchors)
    }
    
    public func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        sessionAnchorRemoved?(session, anchors)
    }
}
