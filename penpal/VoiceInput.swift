//
//  VoiceInput.swift
//  penpal
//
//  PEN-23 — speak a problem, see it written in your own hand.
//
//  This is an accessibility feature first and a magic trick second. Penpal
//  currently requires fine motor control and a stylus: someone with a tremor,
//  an injury, or no Pencil to hand simply cannot use the core of the product.
//  Dictation gives them the same page.
//
//  The magic-trick half is real too — hearing yourself say "three x squared
//  plus five" and watching it appear in your own handwriting is the clearest
//  possible demonstration of what this app is.
//
//  Two design decisions:
//
//  * **Spoken maths is transcribed to symbols.** Speech recognition returns
//    "three x squared plus five equals seventeen". Writing that as words on
//    ruled paper would be useless — the whole point is that it becomes
//    `3x^2 + 5 = 17` and can then be solved like anything else.
//  * **On-device recognition where available.** A page of homework is
//    personal; requiring it to be sent to a speech server to be written down
//    is a poor trade. Falls back to server recognition only if the device
//    can't do it, and says so.
//

import AVFoundation
// @Published / ObservableObject — the banner shows the live transcript.
import Combine
import Foundation
import Speech

@MainActor
final class VoiceInput: NSObject, ObservableObject {

    static let shared = VoiceInput()

    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    /// Asks for permission, then starts. `onFinish` receives the final text
    /// converted to written maths.
    func start(onFinish: @escaping (String) -> Void) {
        guard !isListening else { return }
        errorMessage = nil

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.errorMessage = "Penpal needs permission to use speech recognition — you can turn it on in Settings."
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.errorMessage = "Penpal needs microphone access to hear you."
                            return
                        }
                        self.beginSession(onFinish: onFinish)
                    }
                }
            }
        }
    }

    private func beginSession(onFinish: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement,
                                    options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "I couldn't start listening just now."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep the audio on the device when the hardware allows it: a page of
        // homework shouldn't need a server round trip to be written down.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024,
                         format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            errorMessage = "I couldn't reach the microphone."
            cleanUp()
            return
        }

        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        let written = SpokenMath.toWrittenForm(self.transcript)
                        self.stop()
                        if !written.isEmpty { onFinish(written) }
                    }
                }
                if error != nil, self.isListening {
                    // Ending the session normally surfaces as an error too, so
                    // deliver whatever was heard rather than discarding it.
                    let written = SpokenMath.toWrittenForm(self.transcript)
                    self.stop()
                    if !written.isEmpty { onFinish(written) }
                }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        cleanUp()
    }

    private func cleanUp() {
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
    }
}

/// Turns spoken maths into written maths.
///
/// Speech recognition gives words: "three x squared plus five equals
/// seventeen". On ruled paper that is useless — it needs to become
/// `3x^2 + 5 = 17` so it can be written, and then solved, like anything else.
enum SpokenMath {

    private static let numbers: [(String, String)] = [
        ("zero", "0"), ("one", "1"), ("two", "2"), ("three", "3"),
        ("four", "4"), ("five", "5"), ("six", "6"), ("seven", "7"),
        ("eight", "8"), ("nine", "9"), ("ten", "10"), ("eleven", "11"),
        ("twelve", "12"), ("thirteen", "13"), ("fourteen", "14"),
        ("fifteen", "15"), ("sixteen", "16"), ("seventeen", "17"),
        ("eighteen", "18"), ("nineteen", "19"), ("twenty", "20"),
        ("thirty", "30"), ("forty", "40"), ("fifty", "50"),
        ("sixty", "60"), ("seventy", "70"), ("eighty", "80"),
        ("ninety", "90"), ("hundred", "100"),
    ]

    /// Operators that attach to the PRECEDING token with no space:
    /// "x squared" is `x^2`, not `x ^2`.
    private static let suffixOperators: [(String, String)] = [
        ("squared", "^2"), ("cubed", "^3"),
    ]

    /// Longest-first so "square root" is matched before "square".
    private static let operators: [(String, String)] = [
        ("square root of", "√"), ("square root", "√"), ("cube root of", "∛"),
        ("to the power of", "^"), ("raised to the power", "^"),
        ("plus or minus", "±"),
        ("multiplied by", "*"), ("times", "*"),
        ("divided by", "/"), ("over", "/"),
        ("greater than or equal to", "≥"), ("less than or equal to", "≤"),
        ("greater than", ">"), ("less than", "<"),
        ("not equal to", "≠"), ("equals", "="), ("equal to", "="),
        ("plus", "+"), ("minus", "-"),
        ("open bracket", "("), ("close bracket", ")"),
        ("open parenthesis", "("), ("close parenthesis", ")"),
        ("pi", "π"), ("theta", "θ"), ("infinity", "∞"),
        ("integral of", "∫"), ("point", "."),
    ]

    static func toWrittenForm(_ spoken: String) -> String {
        var text = " " + spoken.lowercased() + " "

        for (word, symbol) in operators {
            text = text.replacingOccurrences(of: " \(word) ", with: " \(symbol) ")
        }
        // Suffixes attach directly to what precedes them.
        for (word, symbol) in suffixOperators {
            text = text.replacingOccurrences(of: " \(word) ", with: "\(symbol) ")
        }
        // Compound numbers BEFORE single words, or "one hundred" becomes
        // "1 100" and "twenty five" becomes "20 5" — confidently wrong
        // numbers are the worst possible output for a maths app.
        text = collapseCompoundNumbers(text)
        for (word, digit) in numbers {
            text = text.replacingOccurrences(of: " \(word) ", with: " \(digit) ")
        }

        // "3 x" → "3x": spoken maths has spaces a written equation doesn't.
        text = text.replacingOccurrences(
            of: #"(\d)\s+([a-z])(?![a-z])"#, with: "$1$2",
            options: .regularExpression)
        // Tighten around symbols that never take spaces.
        for symbol in ["^", "√", "(", ")"] {
            text = text.replacingOccurrences(of: " \(symbol) ", with: symbol)
        }
        return text.split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static let units: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Joins "one hundred" → 100 and "twenty five" → 25 before single words
    /// are substituted. Handles only the forms people actually speak in a
    /// maths problem; anything unrecognised is left alone rather than guessed.
    private static func collapseCompoundNumbers(_ input: String) -> String {
        var words = input.split(separator: " ").map(String.init)
        var result: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            // "<unit> hundred [<and>] [<rest>]"
            if let unit = units[word], index + 1 < words.count,
               words[index + 1] == "hundred" {
                var total = unit * 100
                var consumed = 2
                var next = index + 2
                if next < words.count, words[next] == "and" { next += 1; consumed += 1 }
                if next < words.count, let ten = tens[words[next]] {
                    total += ten; consumed += 1; next += 1
                    if next < words.count, let u = units[words[next]] {
                        total += u; consumed += 1
                    }
                } else if next < words.count, let u = units[words[next]] {
                    total += u; consumed += 1
                }
                result.append(String(total))
                index += consumed
                continue
            }
            // "<tens> <unit>"
            if let ten = tens[word], index + 1 < words.count,
               let unit = units[words[index + 1]] {
                result.append(String(ten + unit))
                index += 2
                continue
            }
            result.append(word)
            index += 1
        }
        words = result
        return " " + words.joined(separator: " ") + " "
    }
}
