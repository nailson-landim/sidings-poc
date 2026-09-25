//
//  ItemPicker.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 9/24/25.
//

import SwiftUI

public struct ItemPicker<Selection: Hashable, Label: View, ItemLabel: View>: View {
    
    @Binding private var selection: Selection
    private let items: [Selection]
    private let label: () -> Label
    private let axis: Axis
    private let itemLabel: (Selection) -> ItemLabel
    
    public init(selection: Binding<Selection>,
                items: [Selection],
                axis: Axis = .horizontal,
                @ViewBuilder itemLabel: @escaping (Selection) -> ItemLabel,
                @ViewBuilder label: @escaping () -> Label) {
        self._selection = selection
        self.items = items
        self.label = label
        self.axis = axis
        self.itemLabel = itemLabel
    }
    
    public var body: some View {
        SegmentedPicker(selection: $selection,
                        axis: axis) {
            label()
        } content: {
            ForEach(items.map { $0 }, id: \.self) { item in
                itemLabel(item)
            }
        }
    }
}

extension ItemPicker where Label == EmptyView {
    
    public init(selection: Binding<Selection>,
                items: [Selection],
                axis: Axis = .horizontal,
                @ViewBuilder itemLabel: @escaping (Selection) -> ItemLabel) {
        self.init(selection: selection,
                  items: items,
                  axis: axis,
                  itemLabel: itemLabel,
                  label: { EmptyView() })
    }
}

extension ItemPicker where Label == Text {
    
    public init<S: StringProtocol>(_ title: S,
                                   selection: Binding<Selection>,
                                   items: [Selection],
                                   axis: Axis = .horizontal,
                                   @ViewBuilder itemLabel: @escaping (Selection) -> ItemLabel) {
        self.init(selection: selection,
                  items: items,
                  axis: axis,
                  itemLabel: itemLabel,
                  label: { Text(title) })
    }
}

extension ItemPicker where Selection: CaseIterable {
    
    public init(selection: Binding<Selection>,
                axis: Axis = .horizontal,
                @ViewBuilder itemLabel: @escaping (Selection) -> ItemLabel,
                @ViewBuilder label: @escaping () -> Label) {
        self.init(selection: selection,
                  items: Selection.allCases.map { $0 },
                  axis: axis,
                  itemLabel: itemLabel,
                  label: label)
    }
}

extension ItemPicker where Label == EmptyView, Selection: CaseIterable {
    
    public init(selection: Binding<Selection>,
                axis: Axis = .horizontal,
                @ViewBuilder itemLabel: @escaping (Selection) -> ItemLabel) {
        self.init(selection: selection,
                  items: Selection.allCases.map { $0 },
                  axis: axis,
                  itemLabel: itemLabel,
                  label: { EmptyView() })
    }
}

extension ItemPicker where Label == Text, Selection: CaseIterable {
    
    public init<S: StringProtocol>(_ title: S,
                                   selection: Binding<Selection>,
                                   axis: Axis = .horizontal,
                                   @ViewBuilder itemLabel: @escaping (Selection) -> ItemLabel) {
        self.init(selection: selection,
                  items: Selection.allCases.map { $0 },
                  axis: axis,
                  itemLabel: itemLabel,
                  label: { Text(title) })
    }
}
