//
//  ReplyEngine.swift
//  penpal
//
//  Decides WHAT to write back. Echo / test font for debugging. "My hand" uses
//  HandAwareReplyProvider: pick replies that maximize coverage of YOUR trained
//  words + fragments — so the page is mostly real ink, without a clumsy
//  70/30 ransom-note mix of perfect words next to synth ones.
//

import PencilKit

enum Reply {
    case echo([PKStroke])   // replay the user's strokes at the reply position
    case text(String)       // render with the stroke font
}

protocol ReplyProvider {
    mutating func reply(toNewInk strokes: [PKStroke]) -> Reply
}

struct EchoReplyProvider: ReplyProvider {
    func reply(toNewInk strokes: [PKStroke]) -> Reply { .echo(strokes) }
}

struct TestSentenceProvider: ReplyProvider {
    private var index = 0
    private let sentences = [
        "Hello! I am your penpal. Write me more!",
        "That was lovely. Tell me about your day?",
        "I like your handwriting. What is on your mind?",
        "Magic ink never lies. Ask me anything!",
    ]

    mutating func reply(toNewInk strokes: [PKStroke]) -> Reply {
        defer { index += 1 }
        return .text(sentences[index % sentences.count])
    }
}

/// Builds replies biased toward vocabulary the user has actually trained.
struct HandAwareReplyProvider: ReplyProvider {
    private var index = 0

    /// Base lines — scored live against the word/fragment bank.
    private let pool = [
        "that was lovely tell me more about your day",
        "i love the way you write tell me more",
        "what a good day to write to you",
        "tell me about your day and all of it",
        "i like your handwriting what is on your mind",
        "hello you write so well tell me more",
        "that was good what a joy to have time with you",
        "write me more about your day love",
        "how was your day tell me all about it",
        "you and i have time what a joy",
    ]

    mutating func reply(toNewInk strokes: [PKStroke]) -> Reply {
        defer { index += 1 }
        let store = PersonalFontStore.shared
        let trained = Set(store.trainedWordList)

        // Dynamic lines from the user's own word bank (when rich enough).
        var candidates = pool
        let bank = Array(trained).sorted()
        if bank.count >= 4 {
            let a = bank[index % bank.count]
            let b = bank[(index + 3) % bank.count]
            let c = bank[(index + 5) % bank.count]
            candidates += [
                "i love \(a) and \(b)",
                "tell me about \(a)",
                "what a \(a) day with \(b)",
                "you write about \(a) and \(c)",
                "\(a) \(b) \(c)",
            ]
        }

        // Softmax-ish: prefer high ink coverage, with a little rotation so it isn't stuck.
        let scored: [(String, CGFloat)] = candidates.map { line in
            let words = line.split(separator: " ").map(String.init)
            guard !words.isEmpty else { return (line, 0) }
            let cover = words.map { store.inkCoverage(of: $0) }.reduce(0, +) / CGFloat(words.count)
            // Slight preference for shorter lines that are fully covered.
            let bonus: CGFloat = cover > 0.85 ? 0.08 : 0
            return (line, cover + bonus)
        }

        let ranked = scored.sorted { $0.1 > $1.1 }
        // Pick among the top few so replies rotate, not always the same winner.
        let top = Array(ranked.prefix(min(4, ranked.count)))
        let pick = top.isEmpty ? pool[index % pool.count] : top[index % top.count].0

        // Light punctuation for human feel (not harvested as words).
        let punctuated: String
        switch index % 3 {
        case 0: punctuated = pick + "?"
        case 1: punctuated = pick + "."
        default: punctuated = pick + "!"
        }
        return .text(punctuated)
    }
}
