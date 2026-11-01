//
//  TourEvents.swift
//  penpal
//
//  Events emitted by canvas gestures, tools and menus that can auto-advance
//  guided tour try-it steps.
//

import Foundation

enum TourEvent: String, Equatable, Hashable {
    case inkWritten
    case penpalToggled
    case boxDrawn
    case strikeDone
    case checkWorkDone
    case equalsSolved
    case askTapped
    case blockInserted
    case workspaceOpened
}

@MainActor
final class TourEventBus {
    static let shared = TourEventBus()
    private init() {}

    var onEvent: ((TourEvent) -> Void)?

    func emit(_ event: TourEvent) {
        onEvent?(event)
    }
}
