//
//  MathGhostWork.swift
//  penpal
//
//  Lightweight "show your work" scratch lines for the ghost-ink beat when the
//  user presses hard on "=". Not a full CAS — just a few readable rewrites
//  that feel like pencil scratch before the answer commits.
//

import Foundation

enum MathGhostWork {

    /// Up to three short scratch lines, or empty when the expression is too
    /// simple / not a shape we can narrate.
    static func steps(for expression: String, answer: String) -> [String] {
        var body = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix("=") { body = String(body.dropLast()) }
        body = body.replacingOccurrences(of: " ", with: "")
        let ans = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 3, !ans.isEmpty else { return [] }

        if let eq = equationSteps(body, answer: ans) { return eq }
        if let arith = arithmeticSteps(body, answer: ans) { return arith }
        return []
    }

    // MARK: - Equations (ax+b=c → ax=c-b → x=…)

    private static func equationSteps(_ body: String, answer: String) -> [String]? {
        let parts = body.split(separator: "=", omittingEmptySubsequences: true)
            .map(String.init)
        guard parts.count == 2,
              let rhs = Double(parts[1].replacingOccurrences(of: "−", with: "-"))
        else { return nil }

        let left = parts[0]
        // Match "3x+5", "3x-5", "x+5", "-2x+7"
        let pattern = #"^([+-]?\d*\.?\d*)([a-zA-Z])([+-]\d+\.?\d*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: left, range: NSRange(left.startIndex..., in: left)),
              m.numberOfRanges == 4,
              let coefR = Range(m.range(at: 1), in: left),
              let varR = Range(m.range(at: 2), in: left),
              let constR = Range(m.range(at: 3), in: left)
        else { return nil }

        let coefRaw = String(left[coefR])
        let variable = String(left[varR])
        let constRaw = String(left[constR]).replacingOccurrences(of: "−", with: "-")
        let coef: Double
        if coefRaw.isEmpty || coefRaw == "+" { coef = 1 }
        else if coefRaw == "-" { coef = -1 }
        else { guard let c = Double(coefRaw) else { return nil }; coef = c }
        guard let constant = Double(constRaw), coef != 0 else { return nil }

        let moved = rhs - constant
        let solved = moved / coef
        let step1 = "\(fmt(coef))\(variable) = \(fmt(moved))"
        let step2 = "\(variable) = \(fmt(solved))"
        // Prefer the engine's answer string if it's nicer ("x = 4").
        if answer.lowercased().contains(variable.lowercased()) {
            return [step1, answer]
        }
        return [step1, step2]
    }

    // MARK: - Arithmetic (one * or / first, then +/−)

    private static func arithmeticSteps(_ body: String, answer: String) -> [String]? {
        // Only narrate when there's a ×/÷ and a +/− — otherwise the answer
        // alone is enough (2+2 doesn't need scratch).
        let hasMulDiv = body.contains(where: { "*/×÷".contains($0) })
        let hasAddSub = body.contains(where: { "+-−".contains($0) })
        guard hasMulDiv, hasAddSub else { return nil }

        // Find the first * or / term pair: a*b or a/b inside the string.
        let pattern = #"(\d+\.?\d*)\s*([*/×÷])\s*(\d+\.?\d*)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let aR = Range(m.range(at: 1), in: body),
              let opR = Range(m.range(at: 2), in: body),
              let bR = Range(m.range(at: 3), in: body),
              let a = Double(body[aR]), let b = Double(body[bR])
        else { return nil }

        let op = String(body[opR])
        let mid: Double
        switch op {
        case "*", "×": mid = a * b
        case "/", "÷": guard b != 0 else { return nil }; mid = a / b
        default: return nil
        }
        let prettyOp = (op == "*" || op == "×") ? "×" : "÷"
        let step1 = "\(fmt(a)) \(prettyOp) \(fmt(b)) = \(fmt(mid))"
        return [step1, answer]
    }

    private static func fmt(_ v: Double) -> String {
        if v.rounded() == v, abs(v) < 1e9 {
            return String(Int(v.rounded()))
        }
        var s = String(format: "%.4g", v)
        if s.hasSuffix(".0") { s = String(s.dropLast(2)) }
        return s
    }
}
