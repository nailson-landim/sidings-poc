//
//  SegmentedPicker.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/11/25.
//

import SwiftUI

fileprivate struct PickerItemAlignmentEnvironmentKey: EnvironmentKey {
    static var defaultValue: HorizontalAlignment { .center }
}

extension EnvironmentValues {
    var pickerItemAlignment: HorizontalAlignment {
        get {
            self[PickerItemAlignmentEnvironmentKey.self]
        } set {
            self[PickerItemAlignmentEnvironmentKey.self] = newValue
        }
    }
}

extension View {
    func pickerItemAlignment(_ alignment: HorizontalAlignment) -> some View {
        environment(\.pickerItemAlignment, alignment)
    }
}

@available(iOS 18.0, *)
public struct SegmentedPicker<Label: View, Content: View, Selection: Hashable>: View {
    
    @Binding private var selection: Selection
    private let axis: Axis
    private let label: () -> Label
    private let content: () -> Content
    
    public init(selection: Binding<Selection>,
                axis: Axis,
                @ViewBuilder label: @escaping () -> Label,
                @ViewBuilder content: @escaping () -> Content) {
        self._selection = selection
        self.axis = axis
        self.label = label
        self.content = content
    }
    
    public init(selection: Binding<Selection>,
                axis: Axis,
                @ViewBuilder content: @escaping () -> Content
    ) where Label == EmptyView {
        self.init(selection: selection,
                  axis: axis,
                  label: { EmptyView() },
                  content: content)
    }
    
    public init<S: StringProtocol>(_ title: S,
                                   selection: Binding<Selection>,
                                   axis: Axis,
                                   @ViewBuilder content: @escaping () -> Content
    ) where Label == Text {
        self.init(selection: selection,
                  axis: axis,
                  label: { Text(title) },
                  content: content)
    }
    
    public var body: some View {
        switch axis {
        case .horizontal:
            HorizontalSegmentedPicker(selection: $selection,
                                      label: label,
                                      content: content)
            .pickerItemAlignment(.center)
        case .vertical:
            VerticalSegmentedPicker(selection: $selection,
                                    label: label,
                                    content: content)
        }
    }
}

@available(iOS 18.0, *)
public struct VerticalSegmentedPicker<
    Label: View,
    Content: View,
    Selection: Hashable
>: View {
    
    @Environment(\.pickerItemAlignment) private var pickerItemAlignment
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    
    @Binding private var selection: Selection
    private let label: () -> Label
    private let content: () -> Content

    @State private var maxBoldLabelWidth: CGFloat = .zero
    @Namespace private var selectionNS

    public init(selection: Binding<Selection>,
                @ViewBuilder label: @escaping () -> Label,
                @ViewBuilder content: @escaping () -> Content) {
        self._selection = selection
        self.label = label
        self.content = content
    }

    public init(selection: Binding<Selection>,
                @ViewBuilder content: @escaping () -> Content
    ) where Label == EmptyView {
        self.init(selection: selection,
                  label: { EmptyView() },
                  content: content)
    }
    
    public init<S: StringProtocol>(_ title: S,
                                   selection: Binding<Selection>,
                                   @ViewBuilder content: @escaping () -> Content
    ) where Label == Text {
        self.init(selection: selection,
                  label: { Text(title) },
                  content: content)
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if Label.self != EmptyView.self {
                label()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            ZStack(alignment: .topLeading) {
                
                // ===== 실제 행들 =====
                Group(subviews: content()) { subviews in
                    VStack(alignment: pickerItemAlignment, spacing: 0) {
                        ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                            // 각 자식의 .tag(Selection) 읽기
                            if let value = subview.containerValues.tag(for: Selection.self) {
                                let isSelected = (value == selection)

                                SegmentItem(isSelected: isSelected,
                                            isEnabled: isEnabled,
                                            alignment: Alignment(horizontal: pickerItemAlignment, vertical: .center),
                                            namespace: selectionNS) {
                                    subview
                                        .font(.callout)
                                        .fontWeight(isSelected ? .semibold : .regular) // 선택 즉시 bold
                                        .animation(nil, value: isSelected)              // ← 폰트 굵기 애니메이션 금지
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.92)) {
                                        selection = value
                                    }
                                }
                                // 마지막 행만 구분선 숨김
                                .overlay(alignment: .bottom) {
                                    if index < subviews.count - 1 {
                                        Divider().opacity(0.35).padding(.leading, 12)
                                    }
                                }
                            } else {
                                // tag 없는 항목은 비활성처럼만 표현(원하면 assert로 바꿔도 됨)
                                subview.opacity(0.5)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    // pill 이동 애니메이션
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selection)
                }

                // ===== 숨김 폭 측정기: 모든 항목을 '굵게' 렌더링한 폭의 최대값 =====
                Group(subviews: content()) { subviews in
                    VStack(spacing: 0) {
                        ForEach(subviews) { subview in
//                            SegmentItem(isSelected: true,
//                                        isEnabled: true,
//                                        alignment: Alignment(horizontal: pickerItemAlignment, vertical: .center),
//                                        namespace: selectionNS) {
                                subview
                                    .font(.callout)
                                    .fontWeight(.semibold) // 선택 시 굵기 기준으로 측정
                                    .fixedSize(horizontal: true, vertical: true)
//                            }
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(key: MaxItemWidthKey.self,
                                                           value: proxy.size.width)
                                }
                            )
                        }
                    }
                    .hidden()
                }
            }
            .background(
                Group {
                    if #available(iOS 26, *) {
                        Color.clear
                            .glassEffect(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        // 배경/보더
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(groupBackground)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 1)
                    }
                }
            )
            .onPreferenceChange(MaxItemWidthKey.self) { maxBoldLabelWidth = $0 }
            .frame(width: maxBoldLabelWidth + 24) // 좌우 내부 패딩 12 * 2
            .fixedSize(horizontal: true, vertical: true)
        }
    }

    // MARK: - Look & Feel
    private var groupBackground: some ShapeStyle {
        colorScheme == .dark ? Color(white: 0.13) : Color(white: 0.94)
    }
    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }
    
    fileprivate struct SegmentItem<ItemContent: View>: View {
        let isSelected: Bool
        let isEnabled: Bool
        let alignment: Alignment
        let namespace: Namespace.ID
        @ViewBuilder var content: () -> ItemContent
        
        fileprivate init(isSelected: Bool,
             isEnabled: Bool,
             alignment: Alignment = .leading,
             namespace: Namespace.ID,
             @ViewBuilder content: @escaping () -> ItemContent) {
            self.isSelected = isSelected
            self.isEnabled = isEnabled
            self.alignment = alignment
            self.namespace = namespace
            self.content = content
        }
        
        fileprivate var body: some View {
            ZStack(alignment: alignment) {
                if isSelected {
                    // 단일 흰색 pill 배경: 행 간 이동
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white)
                        .matchedGeometryEffect(id: "verticalSegSelection", in: namespace)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .accessibilityHidden(true)
                }

//                HStack {
                    content()
                        .foregroundStyle(Color.primary)
//                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .opacity(isEnabled ? 1 : 0.5)
        }
    }
}

@available(iOS 18.0, *)
public struct HorizontalSegmentedPicker<
    Label: View,
    Content: View,
    Selection: Hashable
>: View {
    
    @Environment(\.pickerItemAlignment) private var pickerItemAlignment
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    
    @Binding private var selection: Selection
    private let label: () -> Label
    private let content: () -> Content
    
    @State private var totalBoldLabelWidth: CGFloat = .zero
    @Namespace private var selectionNS
    
    public init(selection: Binding<Selection>,
                @ViewBuilder label: @escaping () -> Label,
                @ViewBuilder content: @escaping () -> Content) {
        self._selection = selection
        self.label = label
        self.content = content
    }
    
    public init(selection: Binding<Selection>,
                @ViewBuilder content: @escaping () -> Content
    ) where Label == EmptyView {
        self.init(selection: selection,
                  label: { EmptyView() },
                  content: content)
    }
    
    public init<S: StringProtocol>(_ title: S,
                                   selection: Binding<Selection>,
                                   @ViewBuilder content: @escaping () -> Content
    ) where Label == Text {
        self.init(selection: selection,
                  label: { Text(title) },
                  content: content)
    }
    
    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if Label.self != EmptyView.self {
                label()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            
            ZStack(alignment: .topLeading) {
                
                Group(subviews: content()) { subviews in
                    HStack(spacing: 0) {
                        ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                            if let value = subview.containerValues.tag(for: Selection.self) {
                                let isSelected = (value == selection)
                                
                                SegmentItem(isSelected: isSelected,
                                            isEnabled: isEnabled,
                                            alignment: Alignment(horizontal: pickerItemAlignment, vertical: .center),
                                            namespace: selectionNS) {
                                    subview
                                        .font(.callout)
                                        .fontWeight(isSelected ? .semibold : .regular)
                                        .animation(nil, value: isSelected)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.92)) {
                                        selection = value
                                    }
                                }
//                                .overlay(alignment: .trailing) {
//                                    if index < subviews.count - 1 {
//                                        Divider().opacity(0.35).padding(.vertical, 12)
//                                    }
//                                }
                            } else {
                                subview.opacity(0.5)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selection)
                }
                
                Group(subviews: content()) { subviews in
                    HStack(spacing: 0) {
                        ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                            HStack {
//                                SegmentItem(isSelected: true,
//                                            isEnabled: true,
//                                            alignment: Alignment(horizontal: pickerItemAlignment, vertical: .center),
//                                            namespace: selectionNS) {
                                    subview
                                        .font(.callout)
                                        .fontWeight(.semibold)
                                        .fixedSize(horizontal: true, vertical: true)
//                                }
                            }
                            .background(
                                GeometryReader { proxy in
                                    if let tag = subview.containerValues.tag(for: Selection.self) {
                                        Color.clear.preference(key: TotalItemWidthKey.self,
                                                               value: [tag: proxy.size.width])
                                    }
                                }
                            )
                        }
                    }
                    .hidden()
                }
            }
            .background(
                Group {
                    if #available(iOS 26, *) {
                        Color.clear
                            .glassEffect(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        // 배경/보더
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(groupBackground)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 1)
                    }
                }
            )
            .onPreferenceChange(TotalItemWidthKey<Selection>.self) { totalBoldLabelWidth = $0.values.reduce(0, +) }
            .frame(width: totalBoldLabelWidth + 24 + 48)
            .fixedSize(horizontal: true, vertical: true)
        }
    }
    
    private var groupBackground: some ShapeStyle {
        colorScheme == .dark ? Color(white: 0.13) : Color(white: 0.94)
    }
    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }
    
    fileprivate struct SegmentItem<ItemContent: View>: View {
        let isSelected: Bool
        let isEnabled: Bool
        let alignment: Alignment
        let namespace: Namespace.ID
        @ViewBuilder var content: () -> ItemContent
        
        fileprivate init(isSelected: Bool,
             isEnabled: Bool,
             alignment: Alignment = .leading,
             namespace: Namespace.ID,
             @ViewBuilder content: @escaping () -> ItemContent) {
            self.isSelected = isSelected
            self.isEnabled = isEnabled
            self.alignment = alignment
            self.namespace = namespace
            self.content = content
        }
        
        fileprivate var body: some View {
            ZStack(alignment: alignment) {
                if isSelected {
                    // 단일 흰색 pill 배경: 행 간 이동
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white)
                        .matchedGeometryEffect(id: "horizontalSegSelection", in: namespace)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .accessibilityHidden(true)
                }

//                HStack {
                    content()
                        .foregroundStyle(Color.primary)
//                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .opacity(isEnabled ? 1 : 0.5)
        }
    }
}

// MARK: - 개별 행 (선택 배경은 여기서만 그림: 단 하나의 matchedGeometryEffect id 공유)


// 선택 라벨(굵게) 폭의 최대값을 수집하기 위한 PreferenceKey
private struct MaxItemWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { .zero }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TotalItemWidthKey<Tag: Hashable>: PreferenceKey {
    static var defaultValue: [Tag: CGFloat] { [:] }
    static func reduce(value: inout [Tag: CGFloat], nextValue: () -> ([Tag: CGFloat])) {
        value.merge(nextValue()) { old, new in max(old, new) }
    }
}
