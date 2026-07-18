//
//  MathIntentChip.swift
//  penpal
//
//  The "did I read this right?" confirmation, like Apple Notes / Google's
//  handwriting math: after you write an expression ending in "=", a chip
//  floats up showing HOW Penpal parsed your ink ("5 × 5") next to a Solve
//  button. Nothing is computed until you tap Solve — so a bad OCR read can
//  never silently become a wrong answer on your page.
//
//  Tap the expression itself to correct it before solving.
//

import UIKit

final class MathIntentChip: UIView {

    /// Called with the (possibly user-corrected) expression when Solve is tapped.
    /// Caller dismisses the chip (e.g. toward the answer) — we don't auto-dismiss
    /// so a failed solve can leave the chip up for another edit.
    var onSolve: ((String) -> Void)?
    /// Called when the chip is dismissed without solving.
    var onDismiss: (() -> Void)?

    private let expressionButton = UIButton(type: .system)
    private let expressionField = UITextField()
    private let solveButton = UIButton(type: .system)
    private let stack = UIStackView()
    private var expression: String
    private let needsReview: Bool

    /// Paper-like graphite — adapts to light/dark instead of system indigo chrome.
    private static var graphite: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.9, alpha: 1)
                : UIColor(red: 0.18, green: 0.17, blue: 0.16, alpha: 1)
        }
    }

    private static var reviewAmber: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 1.0, green: 0.78, blue: 0.35, alpha: 1)
                : UIColor(red: 0.72, green: 0.45, blue: 0.05, alpha: 1)
        }
    }

    /// Pretty display form: 5*5 → "5 × 5", sqrt(2) → "√(2)", pi → "π".
    ///
    /// "/" is deliberately LEFT ALONE: "1/2" is how a fraction reads on
    /// paper, and rewriting it as "1 ÷ 2" made confirmations look wrong
    /// even when the transcription was right.
    static func prettify(_ raw: String) -> String {
        var s = raw
        let swaps: [(String, String)] = [
            ("*", " × "), ("sqrt", "√"), ("pi", "π"),
            ("<=", " ≤ "), (">=", " ≥ "), ("!=", " ≠ "),
        ]
        for (from, to) in swaps { s = s.replacingOccurrences(of: from, with: to) }
        // Space out + and − only between terms, never a leading sign.
        s = s.replacingOccurrences(of: "+", with: " + ")
        // Keep equation equals readable: "3x+5=17" → "… = …"
        if s.contains("=") {
            s = s.replacingOccurrences(of: "=", with: " = ")
        }
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespaces)
    }

    init(expression: String, needsReview: Bool = false) {
        self.expression = expression
        self.needsReview = needsReview
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    private func setup() {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 18
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        addSubview(blur)

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.14
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)

        if needsReview {
            let border = UIView()
            border.translatesAutoresizingMaskIntoConstraints = false
            border.isUserInteractionEnabled = false
            border.layer.cornerRadius = 18
            border.layer.cornerCurve = .continuous
            border.layer.borderWidth = 1.5
            border.layer.borderColor = Self.reviewAmber.withAlphaComponent(0.55).cgColor
            addSubview(border)
            NSLayoutConstraint.activate([
                border.topAnchor.constraint(equalTo: topAnchor),
                border.bottomAnchor.constraint(equalTo: bottomAnchor),
                border.leadingAnchor.constraint(equalTo: leadingAnchor),
                border.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        // The parsed expression — tap to correct it. Empty / uncertain reads
        // get a clear affordance so the chip stays tappable.
        let display: String
        let tint: UIColor
        if expression.isEmpty {
            display = "tap to edit"
            tint = .secondaryLabel
        } else if needsReview {
            display = Self.prettify(expression) + " ?"
            tint = Self.reviewAmber
        } else {
            display = Self.prettify(expression)
            tint = .label
        }
        var exprConfig = UIButton.Configuration.plain()
        exprConfig.attributedTitle = AttributedString(
            display,
            attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 19, weight: .medium),
                .foregroundColor: tint,
            ]))
        exprConfig.baseForegroundColor = tint
        exprConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10,
                                                           bottom: 6, trailing: 10)
        expressionButton.configuration = exprConfig
        expressionButton.addTarget(self, action: #selector(editExpression), for: .touchUpInside)

        expressionField.text = expression
        expressionField.placeholder = "expression"
        expressionField.font = .systemFont(ofSize: 19, weight: .medium)
        expressionField.borderStyle = .roundedRect
        expressionField.autocorrectionType = .no
        expressionField.autocapitalizationType = .none
        expressionField.keyboardType = .asciiCapable
        expressionField.returnKeyType = .go
        expressionField.isHidden = true
        expressionField.delegate = self
        expressionField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

        var config = UIButton.Configuration.filled()
        config.title = "Solve"
        config.image = UIImage(systemName: "equal.circle.fill")
        config.imagePadding = 6
        config.cornerStyle = .capsule
        config.baseBackgroundColor = Self.graphite
        config.baseForegroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? .black : .white
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 16)
        solveButton.configuration = config
        solveButton.addTarget(self, action: #selector(solveTapped), for: .touchUpInside)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        close.tintColor = .tertiaryLabel
        close.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        stack.addArrangedSubview(expressionButton)
        stack.addArrangedSubview(expressionField)
        stack.addArrangedSubview(solveButton)
        stack.addArrangedSubview(close)
        addSubview(stack)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func editExpression() {
        expressionButton.isHidden = true
        expressionField.isHidden = false
        expressionField.becomeFirstResponder()
        expressionField.selectAll(nil)
    }

    @objc private func solveTapped() {
        let edited = (expressionField.isHidden
                      ? expression
                      : (expressionField.text ?? expression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edited.isEmpty else { return }
        expressionField.resignFirstResponder()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onSolve?(edited)
    }

    @objc private func dismissTapped() {
        dismiss(animated: true, notify: true)
    }

    // MARK: - Presentation

    /// Floats the chip in, anchored under `anchor` (the expression's ink),
    /// kept inside `container`'s visible area.
    func present(in container: UIView, below anchor: CGRect, visibleRect: CGRect) {
        translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(self)
        let size = systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)

        var x = anchor.minX
        var y = anchor.maxY + 12
        x = max(visibleRect.minX + 12, min(x, visibleRect.maxX - size.width - 12))
        if y + size.height > visibleRect.maxY - 12 {
            y = max(visibleRect.minY + 12, anchor.minY - size.height - 12)
        }
        frame = CGRect(origin: CGPoint(x: x, y: y), size: size)

        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: -8).scaledBy(x: 0.94, y: 0.94)
        UIView.animate(withDuration: 0.32, delay: 0,
                       usingSpringWithDamping: 0.78, initialSpringVelocity: 0.4,
                       options: [.curveEaseOut]) {
            self.alpha = 1
            self.transform = .identity
        } completion: { _ in
            if self.expression.isEmpty { self.editExpression() }
        }
    }

    /// Shrinks the chip toward the answer origin so Solve → ink feels continuous.
    func dismissToward(_ pointInSuperview: CGPoint, completion: (() -> Void)? = nil) {
        guard let superview else {
            removeFromSuperview()
            completion?()
            return
        }
        let target = convert(pointInSuperview, from: superview)
        let dx = target.x - bounds.midX
        let dy = target.y - bounds.midY
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseIn]) {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: dx, y: dy)
                .scaledBy(x: 0.18, y: 0.18)
        } completion: { _ in
            self.removeFromSuperview()
            completion?()
        }
    }

    func dismiss(animated: Bool, notify: Bool) {
        if notify { onDismiss?() }
        guard animated else { removeFromSuperview(); return }
        UIView.animate(withDuration: 0.18, animations: {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 0, y: -6)
                .scaledBy(x: 0.96, y: 0.96)
        }, completion: { _ in
            self.removeFromSuperview()
        })
    }
}

extension MathIntentChip: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        solveTapped()
        return true
    }
}
