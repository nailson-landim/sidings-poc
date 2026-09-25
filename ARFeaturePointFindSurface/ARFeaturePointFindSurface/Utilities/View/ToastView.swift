//
//  ToastView.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/1/25.
//

import SwiftUI

/// A view that displays a message for a short period of time.
public struct ToastView<Content: View>: View {
    
    /// The message to be displayed in the toast.
//    var message: String
    let content: () -> Content
    
    /// The body of the `ToastView`.
    public var body: some View {
//        Text(message)
//            .monospaced()
        content()
            .padding()
            .tryGlassEffect()
    }
}

/// A view modifier that adds a toast to a view.
public struct ToastModifier<ToastContent: View>: ViewModifier {
    
    @Binding var isShowing: Bool
    let content: () -> ToastContent
    let alignment: Alignment
    let duration: TimeInterval

    @State private var dragOffset: CGSize = .zero
    private let dismissThreshold: CGFloat = 50

    // 추가: 취소 가능한 타이머 Task
    @State private var dismissTask: Task<Void, Never>? = nil

    public func body(content: Content) -> some View {
        ZStack(alignment: alignment) {
            content

            if isShowing {
                self.content()
                    .offset(x: dragOffset.width, y: dragOffset.height)
                    .gesture(dragGesture)
                    .transition(.opacity
                                .combined(with:
                                  .move(edge: alignment.isBottom ? .bottom : .top)
                                )
                    )
                    .onAppear {
                        self.dragOffset = .zero
                        startAutoDismissTimer()
                    }
                    .onDisappear {
                        cancelAutoDismissTimer()
                    }
                    .zIndex(1)
            }
        }
    }

    private func startAutoDismissTimer() {
        // 이전 타이머 취소
        cancelAutoDismissTimer()

        // 새 타이머 시작
        dismissTask = Task {
            // duration 만큼 대기
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }

            // 메인 스레드에서 안전하게 상태 변경
            await MainActor.run {
                if isShowing {
                    withAnimation { isShowing = false }
                }
            }
        }
    }

    private func cancelAutoDismissTimer() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .global)
            .onChanged { gesture in
                var newOffset = CGSize.zero

                let h = gesture.translation.height
                if (alignment.isBottom && h > 0) || (alignment.isTop && h < 0) {
                    newOffset.height = h
                }

                newOffset.width = gesture.translation.width

                self.dragOffset = newOffset
            }
            .onEnded { gesture in
                let h = gesture.translation.height
                let w = gesture.translation.width

                let verticalDismiss =
                    (alignment.isBottom && h > dismissThreshold) ||
                    (alignment.isTop    && h < -dismissThreshold)

                let horizontalDismiss = abs(w) > dismissThreshold

                withAnimation(.spring()) {
                    if verticalDismiss || horizontalDismiss {
                        isShowing = false
                    }
                    dragOffset = .zero
                }
            }
    }
}

private extension Alignment {
    var isBottom: Bool { self == .bottom }
    var isTop:    Bool { self == .top }
}

extension View {
    
    public func toast<Content: View>(
        isShowing: Binding<Bool>,
        alignment: Alignment = .bottom,
        duration: TimeInterval = 2.0,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        self.modifier(
            ToastModifier(isShowing: isShowing, content: content, alignment: alignment, duration: duration)
        )
    }
    
    /// Adds a toast to the view.
    ///
    /// - Parameters:
    ///   - isShowing: A binding to a Boolean value that determines whether to show the toast.
    ///   - message: The message to be displayed in the toast.
    ///   - alignment: The alignment of the toast. Defaults to `.bottom`.
    ///   - duration: The duration for which the toast is shown. Defaults to `2.0`.
    /// - Returns: A view that shows a toast when `isShowing` is `true`.
    public func toast(
        isShowing: Binding<Bool>,
        message: String,
        alignment: Alignment = .bottom,
        duration: TimeInterval = 2.0
    ) -> some View {
        toast(isShowing: isShowing, alignment: alignment, duration: duration) {
            Text(message)
                .padding()
                .tryGlassEffect()
        }
    }
    
    public func toast(
        message: Binding<String>,
        alignment: Alignment = .bottom,
        duration: TimeInterval = 2.0
    ) -> some View {
        let binding = Binding<Bool> {
            !message.wrappedValue.isEmpty
        } set: { showing in
            if !showing { message.wrappedValue = "" }
        }
        return toast(isShowing: binding,
                     message: message.wrappedValue,
                     alignment: alignment,
                     duration: duration)
    }
}

/// A wrapper view for previewing the toast functionality.
fileprivate struct ToastPreviewWrapper: View {
    @State private var showTopToast = false
    @State private var showBottomToast = false

    var body: some View {
        VStack(spacing: 20) {
            Button("Show Top Toast") {
                showTopToast = true
            }
            
            Button("Show Bottom Toast") {
                showBottomToast = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray.opacity(0.1))
        .navigationTitle("Toast Preview")
        .toast(isShowing: $showTopToast, message: "This is a toast at the top.", alignment: .top)
        .toast(isShowing: $showBottomToast, message: "This is a toast at the bottom.", alignment: .bottom)
    }
}

//#Preview {
//    NavigationView {
//        ToastPreviewWrapper()
//    }
//}
