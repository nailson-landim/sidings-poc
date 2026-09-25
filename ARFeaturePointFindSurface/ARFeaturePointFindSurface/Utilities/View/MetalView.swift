//
//  MetalView.swift
//
//  Created by CurvSurf-SGKim on 6/23/25.
//

import Metal
import MetalKit
import SwiftUI

#if os(macOS)
public typealias OSView = NSView
public typealias OSViewRepresentable = NSViewRepresentable
public typealias OSViewRepresentableContext<T: NSViewRepresentable> = NSViewRepresentableContext<T>
#elseif os(iOS)
public typealias OSView = UIView
public typealias OSViewRepresentable = UIViewRepresentable
public typealias OSViewRepresentableContext<T: UIViewRepresentable> = UIViewRepresentableContext<T>
#endif

fileprivate func setViewDefault(_ view: MTKView,
                                _ context: OSViewRepresentableContext<MetalView>) {
    view.preferredFramesPerSecond = 60
    let bgColor: Color = context.environment.colorScheme == .dark ? .black : .white
    #if os(iOS)
    view.backgroundColor = UIColor(bgColor)
    view.isOpaque = true
    #endif
    view.framebufferOnly = true
    let c: Double = bgColor == .black ? 0 : 1
    view.clearColor = MTLClearColorMake(c, c, c, 0)
    view.enableSetNeedsDisplay = false
    view.colorPixelFormat = .bgra8Unorm
    view.depthStencilPixelFormat = .depth32Float
}

public class MetalViewCoordinator: NSObject, MTKViewDelegate {
    
    private let resizeHandler: (MTKView, CGSize) -> Void
    private let drawHandler: (MTKView) -> Void
    
    public init(onResize resizeHandler: @escaping (MTKView, CGSize) -> Void,
                onDraw drawHandler: @escaping (MTKView) -> Void) {
        self.resizeHandler = resizeHandler
        self.drawHandler = drawHandler
    }
    
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        resizeHandler(view, size)
    }
    
    public func draw(in view: MTKView) {
        drawHandler(view)
    }
}

public protocol MetalViewDelegate {
    
    var device: MTLDevice { get }
    
    typealias Context = OSViewRepresentableContext<MetalView>
    func configure(view: MTKView, context: Context)
    func resize(view: MTKView, drawableSize: CGSize)
    func draw(view: MTKView)
}

public struct MetalView: OSViewRepresentable {
    
    public typealias ViewConfigureHandler = (MTKView, OSViewRepresentableContext<MetalView>) -> Void
    public typealias ViewResizeHandler = (MTKView, CGSize) -> Void
    public typealias DrawHandler = (MTKView) -> Void
    
    private let mtkView: MTKView
    private let viewConfigureHandler: ViewConfigureHandler
    private let viewResizeHandler: ViewResizeHandler
    private let drawHandler: DrawHandler
    
    public init(_ device: MTLDevice,
                onViewCreated viewConfigure: @escaping ViewConfigureHandler = { _,_ in () },
                onViewResized viewResize: @escaping ViewResizeHandler = {_,_ in () },
                onDraw draw: @escaping DrawHandler) {
        
        self.mtkView = MTKView(frame: .zero, device: device)
        self.viewConfigureHandler = { view, context in
            setViewDefault(view, context)
            viewConfigure(view, context)
        }
        self.viewResizeHandler = viewResize
        self.drawHandler = draw
    }
    
    public init(delegate: MetalViewDelegate) {
        self.init(delegate.device) { view, context in
            delegate.configure(view: view, context: context)
        } onViewResized: { view, size in
            delegate.resize(view: view, drawableSize: size)
        } onDraw: { view in
            delegate.draw(view: view)
        }
    }
    
    public func makeCoordinator() -> MetalViewCoordinator {
        return MetalViewCoordinator(onResize: self.viewResizeHandler, onDraw: self.drawHandler)
    }
    
    #if os(macOS)
    public func makeNSView(context: Context) -> MTKView {
        let coordinator = context.coordinator
        mtkView.delegate = coordinator
        viewConfigureHandler(mtkView, context)
        return mtkView
    }
    public func updateNSView(_ uiView: MTKView, context: Context) {
        /* do nothing */
    }
    #elseif os(iOS)
    public typealias UIViewType = MTKView
    public func makeUIView(context: Context) -> MTKView {
        let coordinator = context.coordinator
        mtkView.delegate = coordinator
        viewConfigureHandler(mtkView, context)
        return mtkView
    }
    public func updateUIView(_ uiView: MTKView, context: Context) {
        /* do nothing */
    }
    #endif
    
}

