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
    @Published private(set) var justCompleted = false
    @Published private(set) var interactedStepIDs: Set<String> = []
    @Published var preparation: TourPreparation?
    @Published var celebratedEvent: TourEvent?

    let steps = TourStep.allSteps

    private let completedKey = "penpal.tour.v1.completed"
    private let lastIndexKey = "penpal.tour.v1.lastIndex"
    private let startedKey = "penpal.tour.v1.started"

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
        UserDefaults.standard.bool(forKey: startedKey) && !isCompleted
    }

    private init() {
        self.isCompleted = UserDefaults.standard.bool(forKey: "penpal.tour.v1.completed")
        TourEventBus.shared.onEvent = { [weak self] event in
            self?.handle(event: event)
        }
    }

    func start(fromBeginning: Bool = true) {
        justCompleted = false
        interactedStepIDs.removeAll()
        UserDefaults.standard.set(true, forKey: startedKey)
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
        restoreWorkspaceState()
    }

    func finish() {
        isActive = false
        isCompleted = true
        justCompleted = true
        UserDefaults.standard.set(true, forKey: completedKey)
        UserDefaults.standard.removeObject(forKey: lastIndexKey)
        restoreWorkspaceState()
        Pen.tapHaptic()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.justCompleted = false
        }
    }

    func dismissCompletion() {
        justCompleted = false
    }

    func reset() {
        isActive = false
        isCompleted = false
        justCompleted = false
        currentIndex = 0
        interactedStepIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: completedKey)
        UserDefaults.standard.removeObject(forKey: lastIndexKey)
        UserDefaults.standard.removeObject(forKey: startedKey)
    }

    func handle(event: TourEvent) {
        guard isActive else { return }
        if event == .inkWritten, currentStep.anchor == .page {
            interactedStepIDs.insert(currentStep.id)
        }
        switch currentStep.advance {
        case .event(let targetEvent), .eventOrNext(let targetEvent):
            if event == targetEvent {
                celebratedEvent = event
                Pen.tapHaptic()
                let celebratedIndex = currentIndex
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                    guard self?.currentIndex == celebratedIndex,
                          self?.isActive == true else { return }
                    self?.celebratedEvent = nil
                    self?.next()
                }
            }
        case .next:
            break
        }
    }

    private func runPrepareActions() {
        preparation = TourPreparation(actions: currentStep.prepare)
    }

    private func restoreWorkspaceState() {
        preparation = TourPreparation(actions: [
            .showTraining(false),
            .showSettings(false),
            .openSidebar(false),
            .showTools(false),
            .penpal(true),
            .toolbarSection(.pageTools),
        ])
    }
}
