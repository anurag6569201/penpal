//
//  TourAnchor.swift
//  penpal
//
//  Anchor preferences for spotlighting controls across the app.
//

import SwiftUI

struct TourAnchorKey: PreferenceKey {
    typealias Value = [TourAnchorID: Anchor<CGRect>]
    static var defaultValue: [TourAnchorID: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [TourAnchorID: Anchor<CGRect>],
        nextValue: () -> [TourAnchorID: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    /// Tags an interactive control or surface for spotlight highlighting in the guided tour.
    func tourAnchor(_ id: TourAnchorID) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { anchor in
            [id: anchor]
        }
    }
}
