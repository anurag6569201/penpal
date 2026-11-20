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
        if let quad = quadraticSteps(body, answer: ans) { return quad }
        if let pct = percentSteps(body, answer: ans) { return pct }
        if let frac = fractionSteps(body, answer: ans) { return frac }
        if let paren = parenSteps(body, answer: ans) { return paren }
        if let arith = arithmeticSteps(body, answer: ans) { return arith }
        return []
    }

    // MARK: - Quadratics (ax^2 + bx + c = 0 → Δ = b²-4ac → roots)

    private static func quadraticSteps(_ body: String, answer: String) -> [String]? {
        let lower = body.lowercased().replacingOccurrences(of: "²", with: "^2")
            .replacingOccurrences(of: "−", with: "-")
        let parts = lower.split(separator: "=", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2, parts[1] == "0" else { return nil }
        let lhs = parts[0]
        let pattern = #"^([+-]?\d*\.?\d*)([a-z])\^2([+-]\d*\.?\d*)\2([+-]\d+\.?\d*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: lhs, range: NSRange(lhs.startIndex..., in: lhs)),
              m.numberOfRanges == 5,
              let aR = Range(m.range(at: 1), in: lhs),
              let bR = Range(m.range(at: 3), in: lhs),
              let cR = Range(m.range(at: 4), in: lhs)
        else { return nil }

        func parseCoef(_ s: String) -> Double? {
            if s.isEmpty || s == "+" { return 1 }
            if s == "-" { return -1 }
            return Double(s)
        }
        guard let a = parseCoef(String(lhs[aR])), a != 0,
              let b = parseCoef(String(lhs[bR])),
              let c = Double(lhs[cR]) else { return nil }

        let disc = b * b - 4 * a * c
        guard disc >= 0 else { return nil }
        let step1 = "D = \(fmt(b))^2 - 4(\(fmt(a)))(\(fmt(c))) = \(fmt(disc))"
        return [step1, answer]
    }

    // MARK: - Percent ("15% of 80" → "0.15 × 80 = 12")

    private static func percentSteps(_ body: String, answer: String) -> [String]? {
        let lower = body.lowercased()
        let pattern = #"^(\d+\.?\d*)%of(\d+\.?\d*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              m.numberOfRanges == 3,
              let pR = Range(m.range(at: 1), in: lower),
              let nR = Range(m.range(at: 2), in: lower),
              let pct = Double(lower[pR]), let num = Double(lower[nR])
        else { return nil }
        let dec = pct / 100.0
        return ["\(fmt(dec)) × \(fmt(num))", answer]
    }

    // MARK: - Fractions ("a/b + c/d" → common denominator)

    private static func fractionSteps(_ body: String, answer: String) -> [String]? {
        let clean = body.replacingOccurrences(of: "−", with: "-")
        let pattern = #"^(\d+)/(\d+)([+-])(\d+)/(\d+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)),
              m.numberOfRanges == 6,
              let aR = Range(m.range(at: 1), in: clean),
              let bR = Range(m.range(at: 2), in: clean),
              let opR = Range(m.range(at: 3), in: clean),
              let cR = Range(m.range(at: 4), in: clean),
              let dR = Range(m.range(at: 5), in: clean),
              let a = Int(clean[aR]), let b = Int(clean[bR]),
              let c = Int(clean[cR]), let d = Int(clean[dR]),
              b > 0, d > 0, b != d
        else { return nil }
        func gcd(_ x: Int, _ y: Int) -> Int { y == 0 ? x : gcd(y, x % y) }
        let lcm = (b / gcd(b, d)) * d
        let na = a * (lcm / b)
        let nc = c * (lcm / d)
        let op = String(clean[opR])
        return ["(\(na) \(op) \(nc)) / \(lcm)", answer]
    }

    // MARK: - Parentheses ("(2+3)*4" → "5 × 4 = 20")

    private static func parenSteps(_ body: String, answer: String) -> [String]? {
        let pattern = #"\(([^()]+)\)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let innerR = Range(m.range(at: 1), in: body),
              let fullR = Range(m.range, in: body)
        else { return nil }
        let inner = String(body[innerR])
        guard inner.contains(where: { "+-*/×÷^".contains($0) }),
              let innerVal = MathEvaluator.evaluate(MathEvaluator.normalize(inner)),
              innerVal.isFinite else { return nil }
        let reduced = body.replacingCharacters(in: fullR, with: fmt(innerVal))
            .replacingOccurrences(of: "*", with: " × ")
            .replacingOccurrences(of: "/", with: " ÷ ")
        guard reduced != body, reduced != answer else { return nil }
        return ["\(inner) = \(fmt(innerVal))", "\(reduced) = \(answer)"]
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
