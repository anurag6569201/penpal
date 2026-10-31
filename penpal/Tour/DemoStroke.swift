//
//  DemoStroke.swift
//  penpal
//
//  Data model and store for pre-recorded Apple Pencil demo strokes.
//
//  Recorded by the user on device with an Apple Pencil (DemoStrokeRecorder),
//  these strokes drive both:
//  1. The looping animated SVGs in the Penpal Guide folder notes
//  2. The ghost-pencil overlay animations in the interactive tour
//

import Foundation
import CoreGraphics
import PencilKit
import Combine

// MARK: - Point & Stroke Models

struct DemoStrokePoint: Codable, Equatable {
    var x: Double
    var y: Double
    var t: Double
    var f: Double
    var az: Double?
    var al: Double?
}

struct DemoStrokeItem: Codable, Equatable {
    var start: Double
    var duration: Double
    var points: [DemoStrokePoint]
}

struct DemoStrokePage: Codable, Equatable {
    var width: Double
    var lineGap: Double
    var rulesTopInset: Double
}

struct DemoStrokeAnchor: Codable, Equatable {
    var x: Double
    var y: Double
}

struct DemoStroke: Codable, Identifiable, Equatable {
    var id: String
    var version: Int
    var title: String?
    var prompt: String
    var page: DemoStrokePage
    var anchor: DemoStrokeAnchor
    var duration: Double
    var strokes: [DemoStrokeItem]

    init(id: String,
         version: Int = 1,
         title: String? = nil,
         prompt: String,
         page: DemoStrokePage = DemoStrokePage(width: 768, lineGap: 44, rulesTopInset: 40),
         anchor: DemoStrokeAnchor = DemoStrokeAnchor(x: 90, y: 122),
         duration: Double = 0,
         strokes: [DemoStrokeItem] = []) {
        self.id = id
        self.version = version
        self.title = title
        self.prompt = prompt
        self.page = page
        self.anchor = anchor
        self.duration = duration
        self.strokes = strokes
    }

    /// Converts a native PKDrawing into a normalized DemoStroke relative to an anchor point.
    static func from(drawing: PKDrawing,
                     id: String,
                     title: String? = nil,
                     prompt: String,
                     anchor: CGPoint = CGPoint(x: 90, y: 122),
                     pageWidth: CGFloat = 768) -> DemoStroke {
        let sortedStrokes = drawing.strokes.sorted {
            $0.path.creationDate < $1.path.creationDate
        }
        guard let first = sortedStrokes.first else {
            return DemoStroke(id: id, title: title, prompt: prompt)
        }
        let baseDate = first.path.creationDate

        var items: [DemoStrokeItem] = []
        var maxTime: Double = 0

        for stroke in sortedStrokes {
            let strokeStart = max(0, stroke.path.creationDate.timeIntervalSince(baseDate))
            var points: [DemoStrokePoint] = []
            let pts = stroke.path.interpolatedPoints(by: .distance(2.5))
            for p in pts {
                let relX = Double(p.location.x - anchor.x)
                let relY = Double(p.location.y - anchor.y)
                let t = Double(strokeStart + p.timeOffset)
                let f = Double(p.force)
                points.append(DemoStrokePoint(
                    x: relX,
                    y: relY,
                    t: t,
                    f: f,
                    az: Double(p.azimuth),
                    al: Double(p.altitude)
                ))
                if t > maxTime { maxTime = t }
            }
            let strokeDur = points.last.map { max(0.05, $0.t - strokeStart) } ?? 0.1
            items.append(DemoStrokeItem(start: strokeStart, duration: strokeDur, points: points))
        }

        return DemoStroke(
            id: id,
            version: 1,
            title: title,
            prompt: prompt,
            page: DemoStrokePage(width: Double(pageWidth), lineGap: 44, rulesTopInset: 40),
            anchor: DemoStrokeAnchor(x: Double(anchor.x), y: Double(anchor.y)),
            duration: max(maxTime, 0.4),
            strokes: items
        )
    }

    /// Convert back to a PKDrawing positioned at an absolute target anchor on page.
    func toPKDrawing(at origin: CGPoint? = nil, ink: PKInk = PKInk(.pen, color: .label)) -> PKDrawing {
        let baseAnchor = origin ?? CGPoint(x: anchor.x, y: anchor.y)
        var pkStrokes: [PKStroke] = []

        for item in strokes {
            guard !item.points.isEmpty else { continue }
            var strokePoints: [PKStrokePoint] = []
            strokePoints.reserveCapacity(item.points.count)

            let startDate = Date(timeIntervalSince1970: 1000 + item.start)
            for pt in item.points {
                let absPos = CGPoint(x: baseAnchor.x + pt.x, y: baseAnchor.y + pt.y)
                let timeOffset = max(0, pt.t - item.start)
                let point = PKStrokePoint(
                    location: absPos,
                    timeOffset: timeOffset,
                    size: CGSize(width: max(1.5, pt.f * 3.5), height: max(1.5, pt.f * 3.5)),
                    opacity: 1.0,
                    force: CGFloat(pt.f),
                    azimuth: CGFloat(pt.az ?? 0),
                    altitude: CGFloat(pt.al ?? 1.2)
                )
                strokePoints.append(point)
            }

            let path = PKStrokePath(controlPoints: strokePoints, creationDate: startDate)
            let stroke = PKStroke(ink: ink, path: path)
            pkStrokes.append(stroke)
        }

        return PKDrawing(strokes: pkStrokes)
    }
}

// MARK: - Recording Script Item

struct RecordingScriptItem: Identifiable, Equatable {
    var id: String
    var title: String
    var prompt: String
    var instructions: String
    var suggestedAnchor: CGPoint
    var suggestedBox: CGRect

    static let all: [RecordingScriptItem] = [
        RecordingScriptItem(
            id: "hero.question",
            title: "Hero Question",
            prompt: "Hi Penpal! Can you help me plan my week?",
            instructions: "Write clearly in your natural handwriting across 1-2 lines.",
            suggestedAnchor: CGPoint(x: 34, y: 92),
            suggestedBox: CGRect(x: 30, y: 60, width: 580, height: 60)
        ),
        RecordingScriptItem(
            id: "box.question",
            title: "Boxed Equation",
            prompt: "3x + 5 = 17",
            instructions: "Write the equation clearly. Leave room around it to draw a box.",
            suggestedAnchor: CGPoint(x: 90, y: 122),
            suggestedBox: CGRect(x: 80, y: 80, width: 260, height: 60)
        ),
        RecordingScriptItem(
            id: "box.loop",
            title: "Box Gesture",
            prompt: "▢ (Draw a box / rectangle)",
            instructions: "Draw a single continuous rectangular loop around the equation.",
            suggestedAnchor: CGPoint(x: 72, y: 78),
            suggestedBox: CGRect(x: 65, y: 65, width: 290, height: 85)
        ),
        RecordingScriptItem(
            id: "check.l1",
            title: "Check Work: Line 1",
            prompt: "2x + 3 = 11",
            instructions: "Line 1 of a working out example.",
            suggestedAnchor: CGPoint(x: 90, y: 74),
            suggestedBox: CGRect(x: 80, y: 40, width: 220, height: 50)
        ),
        RecordingScriptItem(
            id: "check.l2",
            title: "Check Work: Line 2",
            prompt: "2x = 8",
            instructions: "Line 2 of working out.",
            suggestedAnchor: CGPoint(x: 90, y: 122),
            suggestedBox: CGRect(x: 80, y: 90, width: 150, height: 50)
        ),
        RecordingScriptItem(
            id: "check.l3",
            title: "Check Work: Line 3",
            prompt: "x = 5",
            instructions: "Line 3 of working out (the error to be checked).",
            suggestedAnchor: CGPoint(x: 90, y: 170),
            suggestedBox: CGRect(x: 80, y: 140, width: 130, height: 50)
        ),
        RecordingScriptItem(
            id: "check.underline",
            title: "Double Underline",
            prompt: "‗ (Double underline)",
            instructions: "Draw two horizontal lines right under the last line of working.",
            suggestedAnchor: CGPoint(x: 84, y: 186),
            suggestedBox: CGRect(x: 80, y: 180, width: 160, height: 30)
        ),
        RecordingScriptItem(
            id: "strike.sentence",
            title: "Strike Sentence",
            prompt: "Meet at the old café at 5",
            instructions: "Write the phrase with normal word spacing.",
            suggestedAnchor: CGPoint(x: 70, y: 110),
            suggestedBox: CGRect(x: 60, y: 70, width: 500, height: 60)
        ),
        RecordingScriptItem(
            id: "strike.line",
            title: "Strike-through Gesture",
            prompt: "— (Strike through 'old')",
            instructions: "Draw a single swift line directly across the word 'old'.",
            suggestedAnchor: CGPoint(x: 224, y: 100),
            suggestedBox: CGRect(x: 220, y: 90, width: 80, height: 25)
        ),
        RecordingScriptItem(
            id: "equals.expr",
            title: "Instant Math",
            prompt: "12 × 7 =",
            instructions: "Write the calculation ending with an equals sign.",
            suggestedAnchor: CGPoint(x: 90, y: 160),
            suggestedBox: CGRect(x: 80, y: 120, width: 200, height: 60)
        ),
        RecordingScriptItem(
            id: "graph.cmd",
            title: "Graph Command",
            prompt: "plot sin(x)",
            instructions: "Write the plotting command.",
            suggestedAnchor: CGPoint(x: 40, y: 74),
            suggestedBox: CGRect(x: 35, y: 40, width: 220, height: 55)
        ),
        RecordingScriptItem(
            id: "tour.hello",
            title: "Tour Hello",
            prompt: "hello",
            instructions: "Write a casual greeting for the tour demonstration.",
            suggestedAnchor: CGPoint(x: 100, y: 140),
            suggestedBox: CGRect(x: 90, y: 100, width: 180, height: 60)
        ),
        RecordingScriptItem(
            id: "tour.box",
            title: "Tour Box Hint",
            prompt: "▢ (Box around hello)",
            instructions: "Draw a box surrounding the hello text.",
            suggestedAnchor: CGPoint(x: 80, y: 90),
            suggestedBox: CGRect(x: 75, y: 85, width: 210, height: 85)
        ),
    ]
}

// MARK: - DemoStrokeStore

@MainActor
final class DemoStrokeStore: ObservableObject {
    static let shared = DemoStrokeStore()

    @Published private(set) var recordings: [String: DemoStroke] = [:]
    private let storageDir: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        storageDir = appSupport.appendingPathComponent("DemoStrokes", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        loadSavedRecordings()
    }

    func isRecorded(_ id: String) -> Bool {
        recordings[id] != nil
    }

    func stroke(for id: String) -> DemoStroke? {
        recordings[id]
    }

    func save(_ stroke: DemoStroke) {
        recordings[stroke.id] = stroke
        let fileURL = storageDir.appendingPathComponent("\(stroke.id).json")
        if let data = try? JSONEncoder().encode(stroke) {
            try? data.write(to: fileURL)
        }
    }

    func delete(_ id: String) {
        recordings.removeValue(forKey: id)
        let fileURL = storageDir.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadSavedRecordings() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension.lowercased() == "json" {
            if let data = try? Data(contentsOf: file),
               let stroke = try? JSONDecoder().decode(DemoStroke.self, from: data) {
                recordings[stroke.id] = stroke
            }
        }
    }

    /// Exports all recorded stroke JSON files into a shareable temporary folder.
    func exportDirectoryURL() -> URL? {
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("PenpalDemoStrokes_\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for (id, stroke) in recordings {
            if let data = try? encoder.encode(stroke) {
                let fileURL = exportDir.appendingPathComponent("\(id).json")
                try? data.write(to: fileURL)
            }
        }
        return exportDir
    }
}
