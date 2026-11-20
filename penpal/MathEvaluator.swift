//
//  MathEvaluator.swift
//  penpal
//
//  Apple Notes-style instant math, but a full scientific calculator: when
//  the user handwrites an expression ending in "=", we solve it ON DEVICE —
//  no AI round trip — and write the answer right after their equals sign.
//
//  Grammar: + - * / ^ (right-assoc) % ! mod nCr nPr, parens, |x| bars,
//  sqrt cbrt exp log(any base) ln abs floor ceil round,
//  sin cos tan sec csc cot (degree/radian heuristic), asin acos atan,
//  sinh cosh tanh asinh acosh atanh, constants pi tau e phi,
//  scientific notation (1.5e3), implicit multiplication (2pi, 3(4+5)),
//  degree marks (45°), and chained tape math ("5+5=10+2=" → 12).
//
//  Anything symbolic (variables, solve-for-x, word problems) falls through
//  to the normal reply pipeline, where the Mathematician capability (or a
//  boxed problem) brings in the brain.
//

import Foundation

enum MathEvaluator {

    // MARK: - Public

    /// If the recognized handwriting is a solvable expression ending in "=",
    /// returns the formatted answer to write after the equals. Nil otherwise.
    /// Pass `variables` (e.g. `["r": 5]`) for page-level Math Notes bindings.
    static func instantAnswer(for recognizedText: String,
                              variables: [String: Double] = [:]) -> String? {
        // Only the LAST line matters — earlier lines may be prose, prior work,
        // or variable assignments (e.g. "r = 5\n2*pi*r =").
        let rawLines = recognizedText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let lastLine = rawLines.last else { return nil }

        let trimmed = lastLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("=") else { return nil }
        let body = String(trimmed.dropLast())

        // Collect any inline variable definitions from earlier lines in the
        // same block, merged with page-level variables (newer lines win).
        var mergedVars = variables
        if rawLines.count > 1 {
            let priorVars = extractVariables(from: Array(rawLines.dropLast()),
                                             initial: variables)
            for (k, v) in priorVars { mergedVars[k] = v }
        }

        // Primary engine: math.js in JavaScriptCore (MathEngine). Handles
        // brackets, fractions, the full scientific set, OCR repair, tape
        // chaining, polynomial equations AND page-level variables.
        if let answer = MathEngine.shared.solve(body, variables: mergedVars) {
            return answer
        }

        // Multi-line systems of equations ("x+y=5\nx-y=1=" → "x = 3, y = 2"):
        // only when 2–4 non-empty lines all contain "=" (e.g. boxed or paused system).
        if (2...4).contains(rawLines.count) && rawLines.allSatisfy({ $0.contains("=") }) {
            var sysLines = rawLines
            if let last = sysLines.last, last.hasSuffix("=") {
                sysLines[sysLines.count - 1] = String(last.dropLast())
                    .trimmingCharacters(in: .whitespaces)
            }
            if sysLines.allSatisfy({ $0.contains("=") }),
               let answer = MathEngine.shared.solve(sysLines.joined(separator: "\n")) {
                return answer
            }
        }

        // Fallback: the native parser (engine unavailable / exotic input).
        // Never tape-reduce equations with a free variable — taking only
        // "17" from "3x+5=17" would silently answer the wrong thing.
        if !body.contains("="), !mergedVars.isEmpty {
            let substituted = substituteVariables(body, variables: mergedVars)
            if !Self.hasFreeVariable(substituted),
               let answer = solve(normalize(substituted)) {
                return answer
            }
        }
        if Self.hasFreeVariable(body) { return nil }

        // Chained tape math: "5+5=10" already answered, user continues
        // "+2=" → the line reads "5+5=10+2=". Evaluate only the segment
        // after the last completed equals.
        let segment = body.split(separator: "=", omittingEmptySubsequences: true)
            .last.map(String.init) ?? body

        // Attempt 1: as recognized. Attempt 2: with OCR look-alike repair
        // ("S+S=" is 5+5, "Gp2" is 6p2, "1O0" is 100).
        if let answer = solve(normalize(segment)) { return answer }
        return solve(normalize(repairConfusions(segment)))
    }

    // MARK: - Page-level math variables (e.g. "r = 5", then "2*pi*r =")

    /// Parses a standalone single-letter variable assignment like `r = 5` or
    /// `h = sqrt(16)` or `b = 2a + 1`. Returns nil for solve requests ending
    /// in `=`, equations with multiple variables on the left, or prose.
    static func parseAssignment(_ rawLine: String,
                                knownVariables: [String: Double] = [:]) -> (name: String, value: Double)? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("="), !isTheoryOrProseContext(trimmed) else {
            return nil
        }
        let parts = trimmed.split(separator: "=", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { return nil }
        let lhs = parts[0].lowercased()
        let rhs = parts[1]
        guard lhs.count == 1, let ch = lhs.first,
              ("a"..."z").contains(ch), ch != "e", ch != "i",
              !rhs.isEmpty else { return nil }

        // Direct numeric literal fast-path ("r = 5", "x = -3.5").
        let cleanNum = rhs.replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: "")
        if let direct = Double(cleanNum), direct.isFinite {
            return (lhs, direct)
        }
        // Computable RHS ("a = 3 + 4", "b = 2a", "r = sqrt(25)").
        if let solved = MathEngine.shared.solve(rhs, variables: knownVariables) {
            let pure = solved.components(separatedBy: " = ").last ?? solved
            if let v = Double(pure.trimmingCharacters(in: .whitespaces)), v.isFinite {
                return (lhs, v)
            }
        }
        let substituted = knownVariables.isEmpty ? rhs : substituteVariables(rhs, variables: knownVariables)
        if !hasFreeVariable(substituted),
           let v = evaluate(normalize(substituted)), v.isFinite {
            return (lhs, v)
        }
        return nil
    }

    /// Walks lines top-to-bottom extracting page-level variable assignments.
    static func extractVariables(from lines: [String],
                                 initial: [String: Double] = [:]) -> [String: Double] {
        var vars = initial
        for line in lines {
            if let (name, value) = parseAssignment(line, knownVariables: vars) {
                vars[name] = value
            }
        }
        return vars
    }

    /// Returns the subset of `variables` actually referenced as free variables in `expr`.
    static func referencedVariables(in expr: String,
                                    from variables: [String: Double]) -> [(name: String, value: Double)] {
        guard !variables.isEmpty else { return [] }
        var stripped = expr.lowercased()
        for word in knownWords {
            stripped = stripped.replacingOccurrences(of: word + "(", with: "#(")
            stripped = stripped.replacingOccurrences(of: word, with: "#")
        }
        return variables.keys.sorted().compactMap { name in
            guard stripped.range(of: "(?<![a-z])\(name)(?![a-z])",
                                 options: .regularExpression) != nil,
                  let val = variables[name] else { return nil }
            return (name, val)
        }
    }

    /// Substitutes single-letter variables into an expression, respecting function names.
    static func substituteVariables(_ raw: String, variables: [String: Double]) -> String {
        guard !variables.isEmpty else { return raw }
        var out = raw
        for (name, value) in variables {
            let formatted = format(value)
            let replacement = value < 0 ? "(\(formatted))" : "(\(formatted))"
            out = out.replacingOccurrences(
                of: "(?<![a-zA-Z])\(name)(?![a-zA-Z])",
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return out
    }

    /// True when the text has a letter that isn't a known function/constant
    /// (so "3x+5=17" and "sin(x)=0.5" count, but "sin(30)" does not).
    static func hasFreeVariable(_ raw: String) -> Bool {
        var s = raw.lowercased()
        for word in knownWords {
            s = s.replacingOccurrences(of: word + "(", with: "#(")
            s = s.replacingOccurrences(of: word, with: "#")
        }
        return s.contains { $0.isLetter && ("a"..."z").contains($0) && $0 != "e" }
    }

    /// Additional words valid inside on-device calculator expressions (units,
    /// multi-arg commands, CAS verbs, memory). Kept separate from `knownWords` so
    /// `hasFreeVariable(_:)` and `repairConfusions(_:)` keep their exact semantics.
    private static let calculatorWords: Set<String> = [
        "integrate", "factor", "expand", "simplify", "gcd", "lcm", "det",
        "mean", "median", "std", "ncr", "npr", "log2", "log10", "ans", "deg", "rad",
        "km", "cm", "mm", "mi", "ft", "yd", "in", "inch", "inches",
        "kg", "lb", "lbs", "oz", "mg", "gal", "l", "ml",
        "sec", "min", "minute", "minutes", "hour", "hours", "day", "days",
        "meter", "meters", "mile", "miles", "gram", "grams",
        "liter", "liters", "litre", "litres", "celsius", "fahrenheit", "kelvin",
        "degc", "degf", "foot", "feet", "yard", "yards", "pound", "pounds",
        "ounce", "ounces", "gallon", "gallons", "second", "seconds", "hr", "hrs", "mph",
    ]

    /// True when text appears to be natural language prose, theory notes, or scientific formulas
    /// rather than a direct calculator expression. Prevents Penpal from hijacking notes like
    /// "Force F = ma" or "Let mass be m and acceleration be a".
    static func isTheoryOrProseContext(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let punctuation = CharacterSet(charactersIn: ",;:.!?\"'()[]{}=")
        let tokens = trimmed.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(punctuation))
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return false }

        let theoryKeywords: Set<String> = [
            "let", "mass", "where", "force", "acceleration", "when", "if", "then",
            "we", "and", "is", "are", "of", "for", "with", "be", "have", "has",
            "since", "assume", "prove", "show", "find", "given", "note", "definition",
            "theorem", "law", "equation", "calculate", "state", "from", "by", "in",
            "to", "at", "on", "as", "so", "which", "that", "this", "these", "such",
            "each", "all", "per", "derivative", "integral", "limit", "value",
            "constant", "energy", "work", "power", "momentum", "velocity", "speed"
        ]

        let loweredText = trimmed.lowercased()
        let hasPercentOfIdiom = loweredText.range(
            of: #"\d+(?:\.\d+)?\s*%\s*of\b"#,
            options: .regularExpression
        ) != nil
        let hasUnitToIdiom = loweredText.range(
            of: #"\d+(?:\.\d+)?\s*[a-z]+\s+to\s+[a-z]+\b"#,
            options: .regularExpression
        ) != nil

        var proseScore = 0
        var mathScore = 0

        for (index, token) in tokens.enumerated() {
            let lower = token.lowercased()
            if lower == "of" && hasPercentOfIdiom {
                mathScore += 1
                continue
            }
            if (lower == "to" || lower == "in") && hasUnitToIdiom {
                mathScore += 1
                continue
            }
            if lower == "a" || lower == "b" || lower == "c" || lower == "x" || lower == "y" {
                // Single-letter math variables stay neutral unless flagged by theory words.
                if index == 0, lower == "a", tokens.count > 2 {
                    proseScore += 1
                }
                continue
            }
            if theoryKeywords.contains(lower) {
                proseScore += 2
                continue
            }
            if knownWords.contains(lower) || calculatorWords.contains(lower) {
                mathScore += 1
                continue
            }
            if lower.count >= 3 && lower.allSatisfy({ $0 >= "a" && $0 <= "z" }) {
                proseScore += 1
            } else if lower.contains(where: { $0.isNumber || "^*/+-=%!×÷−√²³".contains($0) }) {
                mathScore += 1
            }
        }

        return proseScore > 0 && proseScore >= mathScore
    }

    /// True when text is structured as a plausible arithmetic calculation attempt
    /// (primarily numbers, arithmetic operators, parentheses) without arbitrary prose or equations.
    static func isPlausibleArithmeticAttempt(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isTheoryOrProseContext(trimmed) { return false }

        let body = trimmed.hasSuffix("=") ? String(trimmed.dropLast()) : trimmed
        let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }

        let hasDigits = clean.contains { $0.isNumber }
        let lowered = clean.lowercased()
        let fnPrefixes = [
            "sqrt(", "cbrt(", "sin(", "cos(", "tan(", "sec(", "csc(", "cot(",
            "asin(", "acos(", "atan(", "sinh(", "cosh(", "tanh(",
            "log(", "log2(", "log10(", "ln(", "abs(", "exp(",
            "floor(", "ceil(", "round(", "gcd(", "lcm(", "ncr(", "npr(",
            "mean(", "median(", "std(", "det(",
        ]
        let hasMathOp = clean.contains { "^*/+-()%!×÷−√²³".contains($0) }
            || fnPrefixes.contains { lowered.contains($0) }
        guard hasDigits && hasMathOp else { return false }

        if hasFreeVariable(clean) { return false }
        return true
    }

    private static func solve(_ expr: String) -> String? {
        guard isSolvableExpression(expr),
              let value = evaluate(expr), value.isFinite else { return nil }
        return format(value)
    }

    /// Maps OCR's classic letter/digit confusions to digits — but never
    /// inside a known function/constant word (sin, mod, log stay intact).
    /// Case matters: "G" reads as 6 but "g" as 9, "B" as 8 but "b" as 6 —
    /// so this runs on the ORIGINAL casing, before normalize lowercases.
    static func repairConfusions(_ raw: String) -> String {
        let confusion: [Character: Character] = [
            "S": "5", "s": "5", "O": "0", "o": "0",
            "I": "1", "i": "1", "l": "1", "|": "1",
            "Z": "2", "z": "2", "G": "6", "g": "9",
            "q": "9", "B": "8", "b": "6", "D": "0",
        ]
        let chars = Array(raw)
        let lower = Array(raw.lowercased())
        var out = ""
        var i = 0
        outer: while i < chars.count {
            for word in knownWords {
                let w = Array(word)
                if i + w.count <= lower.count, Array(lower[i..<(i + w.count)]) == w {
                    out += word
                    i += w.count
                    continue outer
                }
            }
            let ch = chars[i]
            out.append(confusion[ch] ?? ch)
            i += 1
        }
        return out
    }

    // MARK: - Normalization (OCR tolerance)

    /// Function/constant words the parser understands. LONGEST FIRST — this
    /// order matters both for parsing and for validation stripping
    /// ("asinh" must win over "asin", "sinh" over "sin").
    static let knownWords = ["asinh", "acosh", "atanh",
                             "sinh", "cosh", "tanh",
                             "asin", "acos", "atan",
                             "sqrt", "cbrt", "floor", "ceil", "round",
                             "sec", "csc", "cot",
                             "sin", "cos", "tan",
                             "log", "ln", "abs", "exp", "mod",
                             "tau", "phi", "pi", "e"]

    /// Cleans Vision-OCR quirks into strict parser input.
    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased()
        // Radical shorthand: "√144" → "sqrt(144)", before "√" → "sqrt".
        s = s.replacingOccurrences(
            of: #"√\s*(\d+(?:\.\d+)?|pi|tau|phi|[a-z])(?![a-z_(])"#,
            with: "sqrt($1)",
            options: .regularExpression
        )
        // Unicode variants OCR loves to emit.
        let swaps: [(String, String)] = [
            ("×", "*"), ("✕", "*"), ("х", "*"), ("·", "*"), ("•", "*"),
            ("÷", "/"), ("−", "-"), ("–", "-"), ("—", "-"),
            ("²", "^2"), ("³", "^3"), ("**", "^"),
            ("√", "sqrt"), ("π", "pi"), ("τ", "tau"), ("φ", "phi"),
            (",", ""), ("°", "deg"),
        ]
        for (from, to) in swaps { s = s.replacingOccurrences(of: from, with: to) }

        // |x| absolute-value bars → abs(x). Bars alternate open/close.
        if s.contains("|") {
            var out = ""
            var open = false
            for ch in s {
                if ch == "|" {
                    out += open ? ")" : "abs("
                    open.toggle()
                } else {
                    out.append(ch)
                }
            }
            s = out
        }

        // "5 x 3" as multiplication — only when squeezed between digits,
        // so algebra like "3x + 5" (no digit after x) is left for the brain.
        var out = ""
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            if ch == "x" {
                let prev = chars[..<i].last(where: { $0 != " " })
                let next = chars[(i + 1)...].first(where: { $0 != " " })
                if let p = prev, let n = next, p.isNumber || p == ")",
                   n.isNumber || n == "(" || n == "." {
                    out.append("*")
                    continue
                }
            }
            out.append(ch)
        }
        return out.replacingOccurrences(of: " ", with: "")
    }

    /// True when the expression is pure computable math (no free variables).
    static func isSolvableExpression(_ expr: String) -> Bool {
        guard !expr.isEmpty, expr.count <= 160 else { return false }
        var stripped = expr.replacingOccurrences(of: "deg", with: "")
        for word in knownWords {
            stripped = stripped.replacingOccurrences(of: word, with: "#")
        }
        // "c"/"p" survive stripping as nCr/nPr operators ("6c2").
        let allowed = Set("0123456789.+-*/^%()!#cp")
        guard stripped.allSatisfy({ allowed.contains($0) }) else { return false }
        guard stripped.contains(where: { $0.isNumber || $0 == "#" }) else { return false }
        // Something to compute — an operator, function, or bracket. A lone
        // number ("5=") isn't worth answering.
        let operators = Set("+-*/^%!#(cp")
        guard stripped.contains(where: { operators.contains($0) }) else { return false }
        return true
    }

    // MARK: - Recursive-descent parser

    /// Evaluates a normalized expression. Nil on any parse error.
    static func evaluate(_ expr: String, trigInRadians: Bool = false) -> Double? {
        var parser = Parser(Array(expr), trigInRadians: trigInRadians)
        guard let v = parser.parseExpression(), parser.atEnd else { return nil }
        return v
    }

    private struct Parser {
        let chars: [Character]
        let trigInRadians: Bool
        var pos = 0
        /// Set whenever "pi"/"tau"/"deg" is consumed — trig uses it to decide
        /// degrees vs radians (see parseTrig).
        var consumedPi = false

        init(_ chars: [Character], trigInRadians: Bool = false) {
            self.chars = chars
            self.trigInRadians = trigInRadians
        }

        var atEnd: Bool { pos >= chars.count }
        var peek: Character? { pos < chars.count ? chars[pos] : nil }

        mutating func match(_ ch: Character) -> Bool {
            if peek == ch { pos += 1; return true }
            return false
        }

        func matchWordAhead(_ word: String) -> Bool {
            let w = Array(word)
            return pos + w.count <= chars.count
                && Array(chars[pos..<(pos + w.count)]) == w
        }

        mutating func matchWord(_ word: String) -> Bool {
            guard matchWordAhead(word) else { return false }
            pos += word.count
            return true
        }

        /// Does the upcoming input start a primary? (drives implicit
        /// multiplication: "2pi", "3(4+5)", "2sqrt(9)", "(2)(3)").
        func startsPrimary() -> Bool {
            guard let ch = peek else { return false }
            if ch.isNumber || ch == "(" || ch == "." { return true }
            // A function/constant word — but NOT the nCr/nPr/mod operators.
            guard ch.isLetter, ch != "x" else { return false }
            if matchWordAhead("mod") { return false }
            if isCombinator(ch) { return false }
            return true
        }

        /// "c"/"p" acting as nCr / nPr (digit or "(" right after), not the
        /// start of cos/cbrt/csc/ceil/pi/phi.
        func isCombinator(_ ch: Character) -> Bool {
            guard ch == "c" || ch == "p" else { return false }
            for word in MathEvaluator.knownWords
            where word.first == ch && matchWordAhead(word) { return false }
            guard pos + 1 < chars.count else { return false }
            let next = chars[pos + 1]
            return next.isNumber || next == "("
        }

        // expr := term (('+' | '-') term)*
        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let op = peek, op == "+" || op == "-" {
                pos += 1
                guard let rhs = parseTerm() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        // term := factor (('*' | '/' | 'mod' | nCr | nPr | implicit) factor)*
        mutating func parseTerm() -> Double? {
            guard var value = parseFactor() else { return nil }
            while true {
                if let op = peek, op == "*" || op == "/" {
                    pos += 1
                    guard let rhs = parseFactor() else { return nil }
                    if op == "/" {
                        guard rhs != 0 else { return nil }
                        value /= rhs
                    } else {
                        value *= rhs
                    }
                } else if matchWordAhead("mod") {
                    pos += 3
                    guard let rhs = parseFactor(), rhs != 0 else { return nil }
                    value = value.truncatingRemainder(dividingBy: rhs)
                } else if let ch = peek, isCombinator(ch) {
                    pos += 1
                    guard let r = parseFactor(),
                          let combo = Self.combinatoric(n: value, r: r,
                                                        permute: ch == "p") else { return nil }
                    value = combo
                } else if startsPrimary() {
                    // Implicit multiplication: 2pi, 3(4+5), (2)(3), 2sqrt(9)
                    guard let rhs = parseFactor() else { return nil }
                    value *= rhs
                } else {
                    break
                }
            }
            return value
        }

        /// nCr / nPr for integer n, r.
        static func combinatoric(n: Double, r: Double, permute: Bool) -> Double? {
            guard n == n.rounded(), r == r.rounded(),
                  n >= 0, r >= 0, r <= n, n <= 170 else { return nil }
            var result = 1.0
            var i = 0.0
            while i < r {
                result *= (n - i)
                if !permute { result /= (i + 1) }
                i += 1
            }
            return result
        }

        // factor := postfix ('^' factor)?   (right-associative power)
        mutating func parseFactor() -> Double? {
            guard let base = parsePostfix() else { return nil }
            if match("^") {
                // Allow a unary minus in the exponent: 2^-3
                let negative = match("-")
                guard var exp = parseFactor() else { return nil }
                if negative { exp = -exp }
                let v = pow(base, exp)
                return v.isFinite ? v : nil
            }
            return base
        }

        // postfix := unary ('!' | '%' | 'deg')*
        mutating func parsePostfix() -> Double? {
            guard var v = parseUnary() else { return nil }
            while true {
                if match("!") {
                    guard v >= 0, v <= 170, v == v.rounded() else { return nil }
                    var result = 1.0
                    var n = 2.0
                    while n <= v { result *= n; n += 1 }
                    v = result
                } else if match("%") {
                    // Postfix percent: "20%" -> 0.2 (calculator convention).
                    v /= 100
                } else if matchWord("deg") {
                    // "45°" was normalized to "45deg" → radians.
                    v = v * Double.pi / 180
                    consumedPi = true   // already radians; trig must not re-convert
                } else {
                    break
                }
            }
            return v
        }

        // unary := '-' unary | primary
        mutating func parseUnary() -> Double? {
            if match("-") {
                guard let v = parseUnary() else { return nil }
                return -v
            }
            return parsePrimary()
        }

        // primary := function '(' expr ')' | constant | number | '(' expr ')'
        mutating func parsePrimary() -> Double? {
            // ORDER: longest words first (asinh before asin before sin).
            let hyperInverse: [(String, (Double) -> Double)] =
                [("asinh", { Foundation.asinh($0) }),
                 ("acosh", { Foundation.acosh($0) }),
                 ("atanh", { Foundation.atanh($0) })]
            for (word, fn) in hyperInverse where matchWordAhead(word) {
                _ = matchWord(word)
                guard let arg = parseParenArg() else { return nil }
                if word == "acosh", arg < 1 { return nil }
                if word == "atanh", abs(arg) >= 1 { return nil }
                let v = fn(arg)
                return v.isFinite ? v : nil
            }
            let hyper: [(String, (Double) -> Double)] =
                [("sinh", { Foundation.sinh($0) }),
                 ("cosh", { Foundation.cosh($0) }),
                 ("tanh", { Foundation.tanh($0) })]
            for (word, fn) in hyper where matchWordAhead(word) {
                _ = matchWord(word)
                guard let arg = parseParenArg() else { return nil }
                let v = fn(arg)
                return v.isFinite ? v : nil
            }
            let inverseTrig: [(String, (Double) -> Double)] =
                [("asin", { Foundation.asin($0) }),
                 ("acos", { Foundation.acos($0) }),
                 ("atan", { Foundation.atan($0) })]
            for (word, fn) in inverseTrig where matchWordAhead(word) {
                _ = matchWord(word)
                guard let arg = parseParenArg() else { return nil }
                guard word == "atan" || (arg >= -1 && arg <= 1) else { return nil }
                return fn(arg)
            }
            // Reciprocal trig, then plain trig — all share the degree/radian
            // heuristic in parseTrig.
            let trig: [(String, (Double) -> Double)] =
                [("sec", { 1 / Foundation.cos($0) }),
                 ("csc", { 1 / Foundation.sin($0) }),
                 ("cot", { Foundation.cos($0) / Foundation.sin($0) }),
                 ("sin", { Foundation.sin($0) }),
                 ("cos", { Foundation.cos($0) }),
                 ("tan", { Foundation.tan($0) })]
            for (word, fn) in trig where matchWordAhead(word) {
                _ = matchWord(word)
                return parseTrig(fn)
            }
            if matchWord("sqrt") {
                guard let arg = parseParenArg(), arg >= 0 else { return nil }
                return arg.squareRoot()
            }
            if matchWord("cbrt") {
                guard let arg = parseParenArg() else { return nil }
                return cbrt(arg)
            }
            if matchWord("floor") {
                guard let arg = parseParenArg() else { return nil }
                return arg.rounded(.down)
            }
            if matchWord("ceil") {
                guard let arg = parseParenArg() else { return nil }
                return arg.rounded(.up)
            }
            if matchWord("round") {
                guard let arg = parseParenArg() else { return nil }
                return arg.rounded()
            }
            if matchWord("exp") {
                guard let arg = parseParenArg() else { return nil }
                let v = Foundation.exp(arg)
                return v.isFinite ? v : nil
            }
            if matchWord("log") {
                // Optional integer base: log(x)=log10, log2(x), log7(x)…
                var baseDigits = ""
                while let ch = peek, ch.isNumber { baseDigits.append(ch); pos += 1 }
                guard let arg = parseParenArg(), arg > 0 else { return nil }
                if baseDigits.isEmpty { return log10(arg) }
                guard let base = Double(baseDigits), base > 0, base != 1 else { return nil }
                return Foundation.log(arg) / Foundation.log(base)
            }
            if matchWord("ln") {
                guard let arg = parseParenArg(), arg > 0 else { return nil }
                return Foundation.log(arg)
            }
            if matchWord("abs") {
                guard let arg = parseParenArg() else { return nil }
                return Swift.abs(arg)
            }
            if matchWord("tau") { consumedPi = true; return 2 * Double.pi }
            if matchWord("phi") { return (1 + 5.0.squareRoot()) / 2 }
            if matchWord("pi") { consumedPi = true; return Double.pi }
            // "e" the constant — but not when a digit follows (that's either
            // scientific notation, handled in parseNumber, or OCR noise).
            if matchWordAhead("e"),
               !(pos + 1 < chars.count && chars[pos + 1].isNumber) {
                _ = matchWord("e")
                return M_E
            }
            if match("(") {
                guard let inner = parseExpression(), match(")") else { return nil }
                return inner
            }
            return parseNumber()
        }

        /// Handwritten trig heuristic: "sin(30)" means degrees to nearly
        /// everyone with a pen; "sin(pi/2)" or "sin(45°)" is explicit radians.
        /// GraphPlotter passes `trigInRadians: true` so curves plot in radians.
        private mutating func parseTrig(_ fn: (Double) -> Double) -> Double? {
            let piBefore = consumedPi
            consumedPi = false
            guard let arg = parseParenArg() else { return nil }
            let argUsedPi = consumedPi || trigInRadians
            consumedPi = piBefore || argUsedPi
            let radians = argUsedPi ? arg : arg * Double.pi / 180
            let v = fn(radians)
            guard v.isFinite, abs(v) < 1e12 else { return nil }   // tan(90°) etc.
            // Snap float dust so tan(45) prints 1, not 0.9999999999999999.
            return (v * 1e12).rounded() / 1e12
        }

        private mutating func parseParenArg() -> Double? {
            guard match("("), let inner = parseExpression(), match(")") else { return nil }
            return inner
        }

        mutating func parseNumber() -> Double? {
            var digits = ""
            var sawDot = false
            while let ch = peek {
                if ch.isNumber {
                    digits.append(ch)
                } else if ch == ".", !sawDot {
                    sawDot = true
                    digits.append(ch)
                } else {
                    break
                }
                pos += 1
            }
            guard !digits.isEmpty, digits != "." else { return nil }

            // Scientific notation: 1.5e3, 2e-4 — only when digits follow
            // the e (a bare "2e" stays 2 × Euler's constant).
            if peek == "e" {
                let saved = pos
                pos += 1
                var expDigits = ""
                var expSign = ""
                if peek == "-" || peek == "+" { expSign = String(chars[pos]); pos += 1 }
                while let ch = peek, ch.isNumber { expDigits.append(ch); pos += 1 }
                if expDigits.isEmpty {
                    pos = saved   // not scientific — leave "e" for the parser
                } else {
                    digits += "e" + expSign + expDigits
                }
            }
            return Double(digits)
        }
    }

    // MARK: - Formatting

    /// Whole numbers print clean ("10", not "10.0"); everything else trims
    /// to at most 6 decimal places with trailing zeros dropped.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if abs(value) < 1e15, value == value.rounded() {
            return String(Int64(value))
        }
        if abs(value) >= 1e15 {
            // Huge results read better in scientific form.
            return String(format: "%.6g", value)
        }
        var s = String(format: "%.6f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
