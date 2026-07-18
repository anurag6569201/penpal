//
//  MathEngine.swift
//  penpal
//
//  The heavy-duty calculator: math.js (bundled as PenpalMath.js) running in
//  JavaScriptCore. Handles everything a scientific calculator does — nested
//  brackets, fractions with pretty "11/12" answers, trig with the
//  degrees/radians heuristic, logs, factorials, nCr/nPr, mod, percent,
//  scientific notation — PLUS symbolic polynomial equation solving, so
//  "3x+5=17=" answers "x = 4" and "x^2-5x+6=0=" answers both roots, all
//  on device with no AI call.
//
//  MathEvaluator (the hand-rolled native parser) stays as the fallback if
//  the JS engine ever fails to load.
//

import Foundation
import JavaScriptCore

final class MathEngine {

    static let shared = MathEngine()

    private var context: JSContext?
    private var loadFailed = false
    private let queue = DispatchQueue(label: "penpal.mathengine", qos: .userInitiated)

    private init() {}

    /// Loads math.js off the main thread so the first calculation doesn't
    /// stall writing. Call once at startup; safe to call repeatedly.
    func warmUp() {
        queue.async { _ = self.ensureLoaded() }
    }

    /// Evaluates everything before the trailing "=". Returns e.g. "10",
    /// "11/12 = 0.916667", or "x = 4, x = 2" — nil when unsolvable.
    /// Thread-safe: hops to the engine's own queue.
    func solve(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return nil }
        return queue.sync {
            guard let ctx = ensureLoaded(),
                  let fn = ctx.objectForKeyedSubscript("penpalEval"),
                  !fn.isUndefined else { return nil }
            guard let result = fn.call(withArguments: [trimmed]),
                  !result.isNull, !result.isUndefined,
                  let answer = result.toString(),
                  !answer.isEmpty, answer != "null", answer != "undefined" else {
                return nil
            }
            return answer
        }
    }

    // MARK: - Loading

    private func ensureLoaded() -> JSContext? {
        if let context { return context }
        guard !loadFailed else { return nil }
        guard let url = Bundle.main.url(forResource: "PenpalMath", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let ctx = JSContext() else {
            loadFailed = true
            return nil
        }
        ctx.exceptionHandler = { _, exception in
            #if DEBUG
            print("MathEngine JS exception: \(exception?.toString() ?? "?")")
            #endif
        }
        ctx.evaluateScript(source)
        guard let probe = ctx.objectForKeyedSubscript("penpalEval"), !probe.isUndefined else {
            loadFailed = true
            return nil
        }
        context = ctx
        return ctx
    }
}
