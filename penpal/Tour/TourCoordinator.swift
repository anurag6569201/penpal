//
//  TourCoordinator.swift
//  penpal
//
//  State coordinator managing the interactive tour lifecycle, step advancement,
//  try-it events, and persistence.
//

import SwiftUI
import Combine

@MainActor
final class TourCoordinator: ObservableObject {
    static let shared = TourCoordinator()

    @Published private(set) var isActive = false
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var isCompleted: Bool
    @Published var prepareAction: TourPrepare?
    @Published var celebratedEvent: TourEvent?

    let steps = TourStep.allSteps

    private let completedKey = "penpal.tour.v1.completed"
    private let lastIndexKey = "penpal.tour.v1.lastIndex"

    var currentStep: TourStep {
        guard currentIndex >= 0 && currentIndex < steps.count else {
            return steps[0]
        }
        return steps[currentIndex]
    }

    var progressText: String {
        "Step \(currentIndex + 1) of \(steps.count)"
    }

    var hasPreviousTake: Bool {
        UserDefaults.standard.integer(forKey: lastIndexKey) > 0
    }

    private init() {
        self.isCompleted = UserDefaults.standard.bool(forKey: "penpal.tour.v1.completed")
        TourEventBus.shared.onEvent = { [weak self] event in
            self?.handle(event: event)
        }
    }

    func start(fromBeginning: Bool = true) {
        if fromBeginning {
            currentIndex = 0
        } else {
            let saved = UserDefaults.standard.integer(forKey: lastIndexKey)
            currentIndex = (saved >= 0 && saved < steps.count) ? saved : 0
        }
        isActive = true
        Pen.tapHaptic()
        runPrepareActions()
    }

    func next() {
        guard isActive else { return }
        Pen.tapHaptic()
        if currentIndex + 1 < steps.count {
            currentIndex += 1
            UserDefaults.standard.set(currentIndex, forKey: lastIndexKey)
            runPrepareActions()
        } else {
            finish()
        }
    }

    func back() {
        guard isActive, currentIndex > 0 else { return }
        Pen.tapHaptic()
        currentIndex -= 1
        UserDefaults.standard.set(currentIndex, forKey: lastIndexKey)
        runPrepareActions()
    }

    func skip() {
        isActive = false
        UserDefaults.standard.set(currentIndex, forKey: lastIndexKey)
    }

    func finish() {
        isActive = false
        isCompleted = true
        UserDefaults.standard.set(true, forKey: completedKey)
        UserDefaults.standard.removeObject(forKey: lastIndexKey)
        Pen.tapHaptic()
    }

    func reset() {
        isActive = false
        isCompleted = false
        currentIndex = 0
        UserDefaults.standard.removeObject(forKey: completedKey)
        UserDefaults.standard.removeObject(forKey: lastIndexKey)
    }

    func handle(event: TourEvent) {
        guard isActive else { return }
        switch currentStep.advance {
        case .event(let targetEvent), .eventOrNext(let targetEvent):
            if event == targetEvent {
                celebratedEvent = event
                Pen.tapHaptic()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                    self?.celebratedEvent = nil
                    self?.next()
                }
            }
        case .next:
            break
        }
    }

    private func runPrepareActions() {
        for action in currentStep.prepare {
            prepareAction = action
        }
    }
}
