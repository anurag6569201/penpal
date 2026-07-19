"""
PEN-02 — test suite for the Penpal brain.

Covers the pieces that carry correctness risk:
  * mathengine  — CAS parsing, exact results, refusal to guess
  * prompts     — capability routing and the symbol/detail rules
  * gemini      — solve → verify → correct, and every fail-open path
  * views       — input validation and endpoint contracts

No network. The Gemini client is replaced with a fake that records what it
was asked, so we can assert on the SHAPE of each request (did the verifier
actually receive the image? did the CAS hint reach the solver?) rather than
only on the final string.

Run:  python manage.py test chat
"""

from __future__ import annotations

import logging
from unittest.mock import patch

from django.test import SimpleTestCase, override_settings
from rest_framework.test import APIClient

from . import access, gemini, mathengine, routing, telemetry
from .prompts import MATHEMATICIAN_SYSTEM_PROMPT, build_system_prompt
from .views import _clean_history


# --------------------------------------------------------------------------
# Fake Gemini
# --------------------------------------------------------------------------

class FakeResponse:
    def __init__(self, text: str):
        self.text = text
        self.candidates = None


class FakeModels:
    """
    Records every call. `solver` / `verifier` may be a string or a callable
    taking (contents) so a test can vary the reply per call.
    """

    def __init__(self, solver="Ans: 42",
                 verifier='{"verdict": "correct", "reason": "ok"}'):
        self.solver = solver
        self.verifier = verifier
        self.calls = []          # (kind, contents, config)

    def generate_content(self, model, contents, config):
        instruction = config.system_instruction or ""
        kind = "verifier" if "referee" in instruction.lower() else "solver"
        self.calls.append((kind, contents, config))
        source = self.verifier if kind == "verifier" else self.solver
        text = source(contents) if callable(source) else source
        return FakeResponse(text)

    # -- helpers for assertions --------------------------------------------

    def of_kind(self, kind):
        return [c for c in self.calls if c[0] == kind]

    def last_parts(self, kind):
        calls = self.of_kind(kind)
        assert calls, f"no {kind} call was made"
        return calls[-1][1][-1].parts

    @staticmethod
    def part_kinds(parts):
        return ["image" if getattr(p, "inline_data", None) else "text"
                for p in parts]

    @staticmethod
    def part_text(parts):
        return "\n".join(getattr(p, "text", "") or "" for p in parts)


class FakeClient:
    def __init__(self, models: FakeModels):
        self.models = models


class GeminiTestCase(SimpleTestCase):
    """Base class that installs a fake client for the duration of a test."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        # Several tests deliberately blow up the model to prove the pipeline
        # fails open. Those exceptions are logged on purpose in production;
        # here they would bury a genuine failure in tracebacks.
        logging.getLogger("chat.gemini").setLevel(logging.CRITICAL)

    @classmethod
    def tearDownClass(cls):
        logging.getLogger("chat.gemini").setLevel(logging.NOTSET)
        super().tearDownClass()

    def setUp(self):
        super().setUp()
        telemetry.reset()      # counters are process-global
        self.addCleanup(telemetry.reset)

    def install(self, **kwargs) -> FakeModels:
        models = FakeModels(**kwargs)
        patcher = patch.object(gemini, "_client", lambda: FakeClient(models))
        patcher.start()
        self.addCleanup(patcher.stop)
        return models


# --------------------------------------------------------------------------
# mathengine
# --------------------------------------------------------------------------

class MathEngineTests(SimpleTestCase):

    def test_normalizes_handwriting_quirks(self):
        cases = {
            "5 × 3": "5 * 3",
            "10 ÷ 2": "10 / 2",
            "x²": "x^2",
            "5!": "factorial(5)",
            "20% of 250": "(20/100)*250",
        }
        for raw, expected in cases.items():
            self.assertEqual(mathengine.normalize(raw), expected, msg=raw)

    def test_strips_trailing_equals(self):
        self.assertEqual(mathengine.normalize("2+2 ="), "2+2")

    def test_evaluates_exactly(self):
        # Exact first: 5/6, not 0.8333.
        self.assertIn("5/6", mathengine.cas_hint("1/2 + 1/3 ="))

    def test_integers_have_no_decimal_noise(self):
        # "12" not "12 ≈ 12.0000" — the decimal adds nothing for an integer.
        self.assertEqual(mathengine.cas_hint("sqrt(144) ="), "value: 12")

    def test_solves_equations(self):
        hint = mathengine.cas_hint("x^2 - 5x + 6 = 0")
        self.assertIn("2", hint)
        self.assertIn("3", hint)

    def test_solves_systems(self):
        hint = mathengine.cas_hint("2x + y = 7, x - y = 2").replace(" ", "")
        self.assertIn("x=3", hint)

    def test_handles_modular_arithmetic(self):
        self.assertEqual(mathengine.cas_hint("2^10 mod 7 ="), "value: 2")

    def test_returns_nothing_for_prose(self):
        # The CAS must decline rather than guess — a wrong hint is worse than
        # no hint, because the solver treats hints as ground truth.
        for prose in ("what is the meaning of life",
                      "solve the train problem where two trains leave",
                      ""):
            self.assertEqual(mathengine.cas_hint(prose), "", msg=prose)

    def test_never_raises(self):
        for junk in ("((((", "x^^^2", "1/0", "a" * 5000):
            try:
                mathengine.cas_hint(junk)
            except Exception as exc:  # pragma: no cover
                self.fail(f"cas_hint raised on {junk!r}: {exc}")


class CalculusCASTests(SimpleTestCase):
    """PEN-03 — calculus arrives as words as often as symbols."""

    def assertHint(self, problem, expected):
        self.assertIn(expected, mathengine.cas_hint(problem), msg=problem)

    def test_derivatives(self):
        self.assertHint("d/dx x^2 + 3x", "2*x + 3")
        self.assertHint("derivative of sin(x)", "cos(x)")
        self.assertHint("differentiate x^3 with respect to x", "3*x**2")

    def test_indefinite_integrals_include_the_constant(self):
        self.assertHint("integral of x^2 dx", "x**3/3 + C")
        self.assertHint("integrate 2x", "x**2 + C")
        self.assertHint("antiderivative of cos(x)", "sin(x) + C")

    def test_definite_integrals(self):
        self.assertHint("integral of x^2 from 0 to 3", "9")

    def test_integrals_are_self_verified(self):
        # An antiderivative is only reported if differentiating it returns the
        # integrand. A wrong "trusted" hint is worse than no hint, because the
        # solver is told to treat the CAS block as ground truth.
        self.assertHint("integral of 1/x dx", "log(x)")

    def test_limits(self):
        self.assertHint("lim as x->0 of sin(x)/x", "1")
        self.assertHint("limit as x -> oo of 1/x", "0")
        self.assertHint("lim x->2 (x^2-4)/(x-2)", "4")


class LinearAlgebraCASTests(SimpleTestCase):
    """PEN-03 — matrix operations."""

    def test_determinant(self):
        self.assertIn("-2", mathengine.cas_hint("det [[1,2],[3,4]]"))

    def test_inverse(self):
        self.assertIn("-2", mathengine.cas_hint("inverse of [[1,2],[3,4]]"))

    def test_singular_matrix_is_reported_not_crashed(self):
        self.assertIn("none", mathengine.cas_hint("inverse of [[1,2],[2,4]]"))

    def test_eigenvalues_and_rank(self):
        self.assertIn("2", mathengine.cas_hint("eigenvalues of [[2,0],[0,3]]"))
        self.assertIn("1", mathengine.cas_hint("rank of [[1,2],[2,4]]"))

    def test_matrix_output_is_single_line(self):
        # The [CAS] block is line-based; SymPy's matrix printer emits newlines
        # that would corrupt it.
        for problem in ("inverse of [[1,2],[3,4]]", "transpose of [[1,2],[3,4]]"):
            self.assertNotIn("\n", mathengine.cas_hint(problem), msg=problem)


# --------------------------------------------------------------------------
# prompts
# --------------------------------------------------------------------------

class PromptTests(SimpleTestCase):

    def test_capability_routing(self):
        self.assertIn("Mathematician mode",
                      build_system_prompt(capability="mathematician"))
        self.assertNotIn("Mathematician mode",
                         build_system_prompt(capability="companion"))

    def test_unknown_capability_falls_back_to_companion(self):
        self.assertEqual(build_system_prompt(capability="wizard"),
                         build_system_prompt(capability="companion"))

    def test_all_detail_levels_build(self):
        for detail in ("answer", "compact", "full", "proof", "nonsense"):
            prompt = build_system_prompt(capability="mathematician",
                                         math_detail=detail)
            self.assertIn("Trusted CAS", prompt, msg=detail)

    def test_requires_real_symbols_not_ascii_names(self):
        # Regression: replies used to read "sqrt(x)" and "pi" on the page.
        self.assertIn("√(2x+1) never sqrt(2x+1)", MATHEMATICIAN_SYSTEM_PROMPT)
        self.assertIn("π never pi", MATHEMATICIAN_SYSTEM_PROMPT)

    def test_documents_image_input(self):
        self.assertIn("Image input", MATHEMATICIAN_SYSTEM_PROMPT)
        self.assertIn("Reading as:", MATHEMATICIAN_SYSTEM_PROMPT)

    def test_custom_mood_is_embedded(self):
        prompt = build_system_prompt(capability="companion", mood="custom",
                                     custom_mood="a salty old sailor")
        self.assertIn("a salty old sailor", prompt)


# --------------------------------------------------------------------------
# gemini — text pipeline
# --------------------------------------------------------------------------

@override_settings(GEMINI_API_KEY="test-key", GEMINI_MODEL="fake-model")
class MathPipelineTests(GeminiTestCase):

    def test_solve_and_verify_are_both_called(self):
        models = self.install()
        gemini.generate_reply("2+2 =", capability="mathematician")
        self.assertEqual(len(models.of_kind("solver")), 1)
        self.assertEqual(len(models.of_kind("verifier")), 1)

    def test_cas_hint_reaches_the_solver(self):
        models = self.install()
        gemini.generate_reply("x^2 - 5x + 6 = 0", capability="mathematician")
        self.assertIn("[CAS]", models.part_text(models.last_parts("solver")))

    def test_correct_verdict_returns_the_draft_unchanged(self):
        models = self.install(solver="Ans: x = 2, 3")
        reply = gemini.generate_reply("x^2 - 5x + 6 = 0",
                                      capability="mathematician")
        self.assertEqual(reply, "Ans: x = 2, 3")
        self.assertEqual(len(models.of_kind("solver")), 1)  # no correction

    def test_wrong_verdict_triggers_one_correction(self):
        def solver(contents):
            asked = "".join(getattr(p, "text", "") or ""
                            for p in contents[-1].parts)
            if "Redo the problem" in asked:
                return "Ans: x = 2 or x = -2"
            return "Ans: x = 2"

        models = self.install(
            solver=solver,
            verifier='{"verdict": "wrong", "reason": "missed the negative root"}',
        )
        reply = gemini.generate_reply("x^2 = 4 =", capability="mathematician")
        self.assertEqual(reply, "Ans: x = 2 or x = -2")
        # Exactly one retry — never an unbounded correction loop.
        self.assertEqual(len(models.of_kind("solver")), 2)

    def test_correction_is_bounded_even_if_verifier_keeps_objecting(self):
        models = self.install(
            verifier='{"verdict": "wrong", "reason": "still wrong"}')
        gemini.generate_reply("2+2 =", capability="mathematician")
        self.assertEqual(len(models.of_kind("solver")), 2)
        self.assertEqual(len(models.of_kind("verifier")), 1)

    def test_math_uses_temperature_zero(self):
        models = self.install()
        gemini.generate_reply("2+2 =", capability="mathematician")
        self.assertEqual(models.of_kind("solver")[0][2].temperature, 0.0)

    def test_math_preserves_line_structure(self):
        # One step per line is the whole layout contract on ruled paper.
        self.install(solver="Step one\nStep two\n\nAns: 4")
        reply = gemini.generate_reply("2+2 =", capability="mathematician")
        self.assertEqual(reply, "Step one\nStep two\nAns: 4")

    def test_history_is_forwarded(self):
        models = self.install()
        gemini.generate_reply(
            "and again?", capability="mathematician",
            history=[{"role": "user", "content": "earlier problem"},
                     {"role": "assistant", "content": "earlier answer"}],
        )
        contents = models.of_kind("solver")[0][1]
        self.assertEqual(len(contents), 3)
        self.assertEqual(contents[1].role, "model")  # assistant → model


# --------------------------------------------------------------------------
# gemini — verifier robustness (BB-03)
# --------------------------------------------------------------------------

@override_settings(GEMINI_API_KEY="test-key", GEMINI_MODEL="fake-model")
class VerifierRobustnessTests(GeminiTestCase):
    """
    The referee runs on a thinking model with a shared token budget, so its
    JSON can arrive truncated. A broken checker must degrade to "return the
    draft" and must NEVER take down the reply.
    """

    def test_truncated_correct_verdict_keeps_the_draft(self):
        self.install(solver="Ans: 42",
                     verifier='{"verdict": "correct", "reason": "the solution corr')
        self.assertEqual(
            gemini.generate_reply("2+2 =", capability="mathematician"),
            "Ans: 42")

    def test_truncated_wrong_verdict_still_triggers_correction(self):
        def solver(contents):
            asked = "".join(getattr(p, "text", "") or ""
                            for p in contents[-1].parts)
            return "Ans: corrected" if "Redo the problem" in asked else "Ans: wrong"

        self.install(
            solver=solver,
            verifier='{"verdict": "wrong", "reason": "first error on line 2 wh',
        )
        self.assertEqual(
            gemini.generate_reply("2+2 =", capability="mathematician"),
            "Ans: corrected")

    def test_verifier_wrapped_in_markdown_fences_is_parsed(self):
        self.install(solver="Ans: 42",
                     verifier='```json\n{"verdict": "correct", "reason": "ok"}\n```')
        self.assertEqual(
            gemini.generate_reply("2+2 =", capability="mathematician"),
            "Ans: 42")

    def test_verifier_prose_preamble_is_salvaged(self):
        self.install(
            solver="Ans: 42",
            verifier='Sure! {"verdict": "correct", "reason": "ok"} hope that helps')
        self.assertEqual(
            gemini.generate_reply("2+2 =", capability="mathematician"),
            "Ans: 42")

    def test_verifier_crash_fails_open_to_the_draft(self):
        def boom(contents):
            raise RuntimeError("verifier exploded")

        self.install(solver="Ans: 42", verifier=boom)
        self.assertEqual(
            gemini.generate_reply("2+2 =", capability="mathematician"),
            "Ans: 42")

    def test_verifier_total_garbage_fails_open(self):
        self.install(solver="Ans: 42", verifier="I am not JSON at all")
        self.assertEqual(
            gemini.generate_reply("2+2 =", capability="mathematician"),
            "Ans: 42")

    def test_verifier_runs_without_visible_thinking(self):
        # BB-03: thinking tokens shared the budget and truncated the verdict.
        models = self.install()
        gemini.generate_reply("2+2 =", capability="mathematician")
        config = models.of_kind("verifier")[0][2]
        self.assertEqual(config.response_mime_type, "application/json")
        self.assertEqual(config.thinking_config.thinking_budget, 0)

    def test_empty_solver_reply_is_an_error_not_an_empty_page(self):
        self.install(solver="")
        with self.assertRaises(gemini.GeminiError):
            gemini.generate_reply("2+2 =", capability="mathematician")


# --------------------------------------------------------------------------
# gemini — image pipeline (boxed problems)
# --------------------------------------------------------------------------

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 32


@override_settings(GEMINI_API_KEY="test-key", GEMINI_MODEL="fake-model")
class ImagePipelineTests(GeminiTestCase):

    def test_solver_receives_the_image(self):
        models = self.install(solver="Reading as: 1/2 + 1/3\nAns: 5/6")
        gemini.solve_math_image(PNG)
        self.assertIn("image", models.part_kinds(models.last_parts("solver")))

    def test_verifier_also_receives_the_image(self):
        # The referee must re-derive from the handwriting itself, not from the
        # solver's transcription — otherwise it can only check arithmetic, not
        # whether the problem was read correctly.
        models = self.install()
        gemini.solve_math_image(PNG)
        self.assertIn("image", models.part_kinds(models.last_parts("verifier")))

    def test_image_path_runs_the_correction_loop(self):
        def solver(contents):
            asked = "".join(getattr(p, "text", "") or ""
                            for p in contents[-1].parts)
            return "Ans: fixed" if "Redo the problem" in asked else "Ans: first"

        self.install(solver=solver,
                     verifier='{"verdict": "wrong", "reason": "misread fraction"}')
        self.assertEqual(gemini.solve_math_image(PNG), "Ans: fixed")

    def test_empty_image_is_rejected(self):
        self.install()
        with self.assertRaises(gemini.GeminiError):
            gemini.solve_math_image(b"")

    def test_history_is_forwarded_with_the_image(self):
        models = self.install()
        gemini.solve_math_image(PNG,
                                history=[{"role": "user", "content": "before"}])
        contents = models.of_kind("solver")[0][1]
        self.assertEqual(len(contents), 2)
        self.assertIn("image", models.part_kinds(contents[-1].parts))


# --------------------------------------------------------------------------
# gemini — companion path
# --------------------------------------------------------------------------

@override_settings(GEMINI_API_KEY="test-key", GEMINI_MODEL="fake-model")
class CompanionTests(GeminiTestCase):

    def test_companion_is_never_verified(self):
        # Verification is for math. A warm note has no ground truth to check,
        # and a second call would double cost for nothing.
        models = self.install(solver="That sounds like a good day.")
        gemini.generate_reply("hello", capability="companion")
        self.assertEqual(len(models.of_kind("verifier")), 0)

    def test_companion_collapses_newlines(self):
        # Prose is laid out by the handwriting engine, not by the model.
        self.install(solver="One line.\n\nAnother line.")
        self.assertEqual(gemini.generate_reply("hi", capability="companion"),
                         "One line. Another line.")

    def test_companion_keeps_some_creativity(self):
        models = self.install()
        gemini.generate_reply("hi", capability="companion")
        self.assertGreater(models.of_kind("solver")[0][2].temperature, 0.5)

    def test_empty_message_is_rejected(self):
        self.install()
        for blank in ("", "   ", "\n"):
            with self.assertRaises(gemini.GeminiError):
                gemini.generate_reply(blank)

    def test_missing_api_key_is_a_clear_error(self):
        with override_settings(GEMINI_API_KEY=""):
            with self.assertRaises(gemini.GeminiError) as ctx:
                gemini.generate_reply("hi")
            self.assertIn("GEMINI_API_KEY", str(ctx.exception))


# --------------------------------------------------------------------------
# views — input validation (BB-06)
# --------------------------------------------------------------------------

class HistorySanitizerTests(SimpleTestCase):

    def test_non_list_history_is_empty(self):
        for junk in ("string", None, 42, {"a": 1}):
            self.assertEqual(_clean_history(junk), [])

    def test_turn_count_is_capped(self):
        many = [{"role": "user", "content": f"m{i}"} for i in range(500)]
        self.assertEqual(len(_clean_history(many)), 24)

    def test_keeps_the_most_recent_turns(self):
        many = [{"role": "user", "content": f"m{i}"} for i in range(50)]
        self.assertEqual(_clean_history(many)[-1]["content"], "m49")

    def test_turn_length_is_capped(self):
        huge = [{"role": "user", "content": "x" * 99999}]
        self.assertEqual(len(_clean_history(huge)[0]["content"]), 4000)

    def test_malformed_entries_are_dropped(self):
        messy = [{"role": "user", "content": ""}, "not a dict", {"nope": 1},
                 None, {"role": "user", "content": "keep me"}]
        self.assertEqual(_clean_history(messy),
                         [{"role": "user", "content": "keep me"}])

    def test_roles_are_normalized(self):
        mixed = [{"role": "human", "content": "a"},
                 {"role": "model", "content": "b"},
                 {"role": "SHOUTING", "content": "c"}]
        self.assertEqual([t["role"] for t in _clean_history(mixed)],
                         ["user", "assistant", "assistant"])


# --------------------------------------------------------------------------
# views — endpoint contracts
# --------------------------------------------------------------------------

def _b64(raw: bytes) -> str:
    import base64
    return base64.b64encode(raw).decode()


@override_settings(GEMINI_API_KEY="test-key", GEMINI_MODEL="fake-model")
class EndpointTests(GeminiTestCase):

    def setUp(self):
        self.api = APIClient()

    # -- health ------------------------------------------------------------

    def test_health(self):
        response = self.api.get("/api/health/")
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()["ok"])

    # -- chat --------------------------------------------------------------

    def test_chat_returns_a_reply(self):
        self.install(solver="Hello there.")
        response = self.api.post("/api/chat/", {"message": "hi"}, format="json")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["reply"], "Hello there.")

    def test_chat_requires_a_message(self):
        self.install()
        for body in ({}, {"message": ""}, {"message": "   "}):
            response = self.api.post("/api/chat/", body, format="json")
            self.assertEqual(response.status_code, 400, msg=body)

    def test_chat_rejects_non_list_history(self):
        self.install()
        response = self.api.post(
            "/api/chat/", {"message": "hi", "history": "nope"}, format="json")
        self.assertEqual(response.status_code, 400)

    def test_chat_caps_an_oversized_message(self):
        # Denial-of-wallet guard: the server must not trust the client.
        models = self.install()
        response = self.api.post(
            "/api/chat/", {"message": "x" * 50000}, format="json")
        self.assertEqual(response.status_code, 200)
        sent = models.part_text(models.last_parts("solver"))
        self.assertLessEqual(len(sent), 4100)

    def test_chat_falls_back_to_companion_for_unknown_capability(self):
        self.install()
        response = self.api.post(
            "/api/chat/", {"message": "hi", "capability": "wizard"},
            format="json")
        self.assertEqual(response.json()["capability"], "companion")

    def test_chat_surfaces_brain_failure_as_503(self):
        def boom(contents):
            raise RuntimeError("upstream down")

        self.install(solver=boom)
        response = self.api.post("/api/chat/", {"message": "hi"}, format="json")
        self.assertEqual(response.status_code, 503)
        self.assertIn("error", response.json())

    # -- solve-math --------------------------------------------------------

    def test_solve_math_returns_a_reply(self):
        self.install(solver="Reading as: 2+2\nAns: 4")
        response = self.api.post(
            "/api/solve-math/", {"image": _b64(PNG)}, format="json")
        self.assertEqual(response.status_code, 200)
        self.assertIn("Ans: 4", response.json()["reply"])

    def test_solve_math_requires_an_image(self):
        self.install()
        for body in ({}, {"image": ""}, {"image": "   "}):
            response = self.api.post("/api/solve-math/", body, format="json")
            self.assertEqual(response.status_code, 400, msg=body)

    def test_solve_math_rejects_non_base64(self):
        self.install()
        response = self.api.post(
            "/api/solve-math/", {"image": "not!base64!"}, format="json")
        self.assertEqual(response.status_code, 400)

    def test_solve_math_accepts_a_data_url(self):
        self.install(solver="Ans: 4")
        response = self.api.post(
            "/api/solve-math/",
            {"image": "data:image/png;base64," + _b64(PNG)}, format="json")
        self.assertEqual(response.status_code, 200)

    def test_solve_math_rejects_an_oversized_image(self):
        self.install()
        response = self.api.post(
            "/api/solve-math/", {"image": _b64(b"\x00" * (7 * 1024 * 1024))},
            format="json")
        self.assertEqual(response.status_code, 400)

    def test_solve_math_is_always_mathematician(self):
        self.install()
        response = self.api.post(
            "/api/solve-math/", {"image": _b64(PNG)}, format="json")
        self.assertEqual(response.json()["capability"], "mathematician")


# --------------------------------------------------------------------------
# telemetry (PEN-04)
# --------------------------------------------------------------------------

@override_settings(GEMINI_API_KEY="test-key", GEMINI_MODEL="fake-model")
class TelemetryTests(GeminiTestCase):
    """
    The point of this module is to make BB-03 impossible to hide: verification
    silently not running, while every answer still looked verified.
    """

    def test_healthy_when_verification_works(self):
        self.install()
        for _ in range(5):
            gemini.generate_reply("2+2 =", capability="mathematician")
        snap = telemetry.snapshot()
        self.assertEqual(snap["status"], "healthy")
        self.assertEqual(snap["verification_coverage"], 1.0)
        self.assertEqual(snap["verified"], 5)
        self.assertEqual(snap["failed_open"], 0)

    def test_bb03_scenario_reports_unverified(self):
        # The exact production failure: the referee raises every time. The
        # replies still come back fine — which is precisely why this needs to
        # be visible somewhere.
        def boom(contents):
            raise RuntimeError("Unterminated string starting at line 1")

        self.install(solver="Ans: 42", verifier=boom)
        for _ in range(4):
            reply = gemini.generate_reply("2+2 =", capability="mathematician")
            self.assertEqual(reply, "Ans: 42")   # user sees nothing wrong

        snap = telemetry.snapshot()
        self.assertEqual(snap["status"], "unverified")
        self.assertEqual(snap["verification_coverage"], 0.0)
        self.assertEqual(snap["failed_open"], 4)
        self.assertTrue(snap["recent_degradations"])

    def test_partial_failure_reports_degraded(self):
        calls = {"n": 0}

        def flaky(contents):
            calls["n"] += 1
            if calls["n"] % 2 == 0:
                raise RuntimeError("verifier hiccup")
            return '{"verdict": "correct", "reason": "ok"}'

        self.install(verifier=flaky)
        for _ in range(4):
            gemini.generate_reply("2+2 =", capability="mathematician")
        self.assertEqual(telemetry.snapshot()["status"], "degraded")

    def test_salvaged_verdicts_are_counted(self):
        # Salvage keeps the reply working, but it still means the referee is
        # misbehaving — worth seeing before it becomes a total failure.
        self.install(verifier='{"verdict": "correct", "reason": "trunc')
        gemini.generate_reply("2+2 =", capability="mathematician")
        self.assertEqual(telemetry.snapshot()["salvaged_verdicts"], 1)

    def test_caught_errors_and_corrections_are_counted(self):
        self.install(solver="Ans: wrong",
                     verifier='{"verdict": "wrong", "reason": "nope"}')
        gemini.generate_reply("2+2 =", capability="mathematician")
        snap = telemetry.snapshot()
        self.assertEqual(snap["caught_errors"], 1)
        self.assertEqual(snap["corrections_applied"], 1)

    def test_cas_hits_and_misses_are_counted(self):
        self.install()
        gemini.generate_reply("x^2 - 5x + 6 = 0", capability="mathematician")
        gemini.generate_reply("tell me about trains", capability="mathematician")
        snap = telemetry.snapshot()
        self.assertEqual(snap["cas_hits"], 1)
        self.assertEqual(snap["cas_misses"], 1)

    def test_idle_before_any_traffic(self):
        self.assertEqual(telemetry.snapshot()["status"], "idle")

    def test_health_endpoint_exposes_verification(self):
        self.install()
        gemini.generate_reply("2+2 =", capability="mathematician")
        payload = APIClient().get("/api/health/").json()
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["verification"]["status"], "healthy")

    def test_telemetry_never_raises(self):
        # Telemetry must not be able to break a reply.
        telemetry.record(None)                      # type: ignore[arg-type]
        telemetry.record("x", detail="y" * 10000)
        self.assertIsInstance(telemetry.snapshot(), dict)

    def test_event_log_is_bounded(self):
        for i in range(500):
            telemetry.record(telemetry.VERIFY_FAILED_OPEN, f"e{i}")
        snap = telemetry.snapshot()
        self.assertEqual(snap["failed_open"], 500)
        self.assertLessEqual(len(snap["recent_degradations"]), 10)


# --------------------------------------------------------------------------
# worksheet mode (PEN-15)
# --------------------------------------------------------------------------

SHEET = ('{"problems": ['
         '{"label": "1", "reading": "2+2", "steps": ["2+2"], "answer": "4"},'
         '{"label": "2", "reading": "x^2=9", "steps": [], "answer": "x = ±3"},'
         '{"label": "3", "reading": "1/2+1/3", "steps": [], "answer": "5/6"}'
         ']}')


@override_settings(GEMINI_API_KEY="test-key", GEMINI_MODEL="fake-model")
class WorksheetTests(GeminiTestCase):
    """
    PEN-15. The structural requirement is that results are PER PROBLEM, so the
    app can place each answer beside its own question — and so one bad answer
    cannot cost the user the rest of the page.
    """

    def test_returns_one_entry_per_problem(self):
        self.install(solver=SHEET, verifier='{"wrong": []}')
        problems = gemini.solve_worksheet(PNG)
        self.assertEqual([p["label"] for p in problems], ["1", "2", "3"])
        self.assertEqual(problems[1]["answer"], "x = ±3")

    def test_solver_receives_the_image(self):
        models = self.install(solver=SHEET, verifier='{"wrong": []}')
        gemini.solve_worksheet(PNG)
        self.assertIn("image", models.part_kinds(models.last_parts("solver")))

    def test_verifier_also_receives_the_image(self):
        # The referee must re-read the page itself: a correctly-solved
        # MISREADING is still wrong, and only the image can catch that.
        models = self.install(solver=SHEET, verifier='{"wrong": []}')
        gemini.solve_worksheet(PNG)
        self.assertIn("image", models.part_kinds(models.last_parts("verifier")))

    def test_only_flagged_problems_are_rewritten(self):
        fixed = SHEET.replace('"answer": "x = ±3"', '"answer": "x = 3 or x = -3"')

        def solver(contents):
            asked = "".join(getattr(p, "text", "") or ""
                            for p in contents[-1].parts)
            return fixed if "referee checked your worksheet" in asked else SHEET

        self.install(
            solver=solver,
            verifier='{"wrong": [{"label": "2", "reason": "incomplete",'
                     ' "answer": "x = 3 or x = -3"}]}')
        problems = gemini.solve_worksheet(PNG)
        # The flagged one is fixed; the others survive untouched.
        self.assertEqual(problems[1]["answer"], "x = 3 or x = -3")
        self.assertEqual(problems[0]["answer"], "4")
        self.assertEqual(problems[2]["answer"], "5/6")

    def test_verifier_failure_keeps_the_solved_page(self):
        # Losing a whole solved worksheet to a broken checker would be a far
        # worse outcome than shipping it unverified.
        def boom(contents):
            raise RuntimeError("referee exploded")

        self.install(solver=SHEET, verifier=boom)
        self.assertEqual(len(gemini.solve_worksheet(PNG)), 3)
        self.assertEqual(telemetry.snapshot()["failed_open"], 1)

    def test_unreadable_problems_are_marked_not_dropped(self):
        # A problem we cannot read must still appear, so the app can show the
        # student we saw it and could not read it — silence looks like success.
        self.install(
            solver='{"problems": [{"label": "1", "reading": "?", "answer": "",'
                   ' "readable": false}, {"label": "2", "answer": "7"}]}',
            verifier='{"wrong": []}')
        problems = gemini.solve_worksheet(PNG)
        self.assertEqual(len(problems), 2)
        self.assertFalse(problems[0]["readable"])
        self.assertTrue(problems[1]["readable"])

    def test_answerless_problem_is_never_marked_readable(self):
        # Guards against the model claiming readable:true with no answer.
        self.install(
            solver='{"problems": [{"label": "1", "answer": "", "readable": true}]}',
            verifier='{"wrong": []}')
        self.assertFalse(gemini.solve_worksheet(PNG)[0]["readable"])

    def test_markdown_fenced_json_is_parsed(self):
        self.install(solver=f"```json\n{SHEET}\n```", verifier='{"wrong": []}')
        self.assertEqual(len(gemini.solve_worksheet(PNG)), 3)

    def test_prose_wrapped_json_is_salvaged(self):
        self.install(solver=f"Sure! Here you go:\n{SHEET}\nHope that helps.",
                     verifier='{"wrong": []}')
        self.assertEqual(len(gemini.solve_worksheet(PNG)), 3)

    def test_unparseable_output_is_a_clear_error(self):
        self.install(solver="I could not read this page at all")
        with self.assertRaises(gemini.GeminiError):
            gemini.solve_worksheet(PNG)

    def test_empty_page_is_an_error_not_an_empty_success(self):
        self.install(solver='{"problems": []}')
        with self.assertRaises(gemini.GeminiError):
            gemini.solve_worksheet(PNG)

    def test_malformed_entries_are_dropped(self):
        self.install(
            solver='{"problems": ["junk", null, 42,'
                   ' {"label": "1", "answer": "4"}]}',
            verifier='{"wrong": []}')
        problems = gemini.solve_worksheet(PNG)
        self.assertEqual(len(problems), 1)
        self.assertEqual(problems[0]["answer"], "4")

    def test_problem_count_and_field_sizes_are_bounded(self):
        many = ('{"problems": ['
                + ",".join(f'{{"label": "{i}", "answer": "{"x" * 900}",'
                           f' "steps": {["s"] * 40}}}'.replace("'", '"')
                           for i in range(120))
                + "]}")
        self.install(solver=many, verifier='{"wrong": []}')
        problems = gemini.solve_worksheet(PNG)
        self.assertLessEqual(len(problems), 60)
        self.assertLessEqual(len(problems[0]["answer"]), 400)
        self.assertLessEqual(len(problems[0]["steps"]), 20)

    def test_empty_image_is_rejected(self):
        self.install()
        with self.assertRaises(gemini.GeminiError):
            gemini.solve_worksheet(b"")

    def test_detail_level_reaches_the_prompt(self):
        models = self.install(solver=SHEET, verifier='{"wrong": []}')
        gemini.solve_worksheet(PNG, math_detail="proof")
        self.assertIn("Detail level: Proof",
                      models.of_kind("solver")[0][2].system_instruction)

    # -- problem positions -------------------------------------------------

    def test_box_is_normalised_to_fractions(self):
        # Model speaks 0–1000 top-left; the app wants fractions of the image.
        self.install(
            solver='{"problems": [{"label": "1", "answer": "4",'
                   ' "box": [100, 50, 300, 450]}]}',
            verifier='{"wrong": []}')
        box = gemini.solve_worksheet(PNG)[0]["box"]
        self.assertAlmostEqual(box["y"], 0.10)
        self.assertAlmostEqual(box["x"], 0.05)
        self.assertAlmostEqual(box["height"], 0.20)
        self.assertAlmostEqual(box["width"], 0.40)

    def test_bad_boxes_become_nil_rather_than_wrong_positions(self):
        # An answer placed beside the WRONG question is worse than one flowed
        # to the bottom of the page, so anything suspect is discarded.
        for bad in ("[]", "[1,2,3]", '"nope"', "null",
                    "[300, 50, 100, 450]",      # inverted
                    "[0, 0, 0, 0]",             # empty
                    "[100, 50, 300, 5000]"):    # out of range
            self.install(
                solver='{"problems": [{"label": "1", "answer": "4",'
                       f' "box": {bad}}}]}}',
                verifier='{"wrong": []}')
            self.assertIsNone(gemini.solve_worksheet(PNG)[0]["box"], msg=bad)

    def test_missing_box_is_allowed(self):
        self.install(solver=SHEET, verifier='{"wrong": []}')
        self.assertIsNone(gemini.solve_worksheet(PNG)[0]["box"])


@override_settings(GEMINI_API_KEY="test-key", GEMINI_MODEL="fake-model")
class WorksheetEndpointTests(GeminiTestCase):

    def setUp(self):
        super().setUp()
        self.api = APIClient()

    def test_returns_structured_problems(self):
        self.install(solver=SHEET, verifier='{"wrong": []}')
        response = self.api.post("/api/worksheet/", {"image": _b64(PNG)},
                                 format="json")
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["count"], 3)
        self.assertEqual(payload["problems"][0]["label"], "1")

    def test_requires_an_image(self):
        self.install()
        self.assertEqual(
            self.api.post("/api/worksheet/", {}, format="json").status_code, 400)

    def test_brain_failure_is_a_503(self):
        self.install(solver='{"problems": []}')
        self.assertEqual(
            self.api.post("/api/worksheet/", {"image": _b64(PNG)},
                          format="json").status_code, 503)


# --------------------------------------------------------------------------
# show-your-work grading (PEN-16)
# --------------------------------------------------------------------------

FLAG = ('{"problem": "3x + 5 = 17", "verdict": "error", "line_number": 2,'
        ' "line_text": "3x = 22", "box": [200, 100, 260, 400],'
        ' "reason": "You added 5 instead of subtracting it.",'
        ' "correction": "3x = 12", "final_answer": "x = 4"}')
CLEAN = ('{"problem": "3x + 5 = 17", "verdict": "correct", "line_number": null,'
         ' "line_text": "", "box": null, "reason": "", "correction": "",'
         ' "final_answer": "x = 4"}')


class GraderHarness:
    """
    Installs a fake client that routes the grader's confirmation pass to
    `referee` and the marking pass to `marker`. The confirmation pass is
    identified by its own instruction text rather than the word "referee",
    which the solver pipeline also uses.
    """

    def install_grader(self, marker=CLEAN, referee='{"real": true}'):
        models = FakeModels(solver=marker, verifier=referee)

        def generate_content(model, contents, config):
            instruction = config.system_instruction or ""
            kind = "verifier" if "FALSE ACCUSATION" in instruction else "solver"
            models.calls.append((kind, contents, config))
            source = models.verifier if kind == "verifier" else models.solver
            return FakeResponse(source(contents) if callable(source) else source)

        models.generate_content = generate_content
        patcher = patch.object(gemini, "_client", lambda: FakeClient(models))
        patcher.start()
        self.addCleanup(patcher.stop)
        return models


@override_settings(GEMINI_API_KEY="test-key", GEMINI_MODEL="fake-model")
class GradingTests(GraderHarness, GeminiTestCase):
    """
    PEN-16. The safety property is INVERTED relative to solving: telling a
    student their correct line is wrong costs far more trust than missing a
    slip. So every claimed error is double-checked, and anything uncertain
    degrades to "looks right".
    """

    # -- the core promise --------------------------------------------------

    def test_reports_the_first_wrong_line(self):
        self.install_grader(marker=FLAG)
        result = gemini.grade_working(PNG)
        self.assertEqual(result["verdict"], "error")
        self.assertEqual(result["line_number"], 2)
        self.assertEqual(result["correction"], "3x = 12")

    def test_correct_working_is_left_alone(self):
        self.install_grader(marker=CLEAN)
        result = gemini.grade_working(PNG)
        self.assertEqual(result["verdict"], "correct")
        self.assertIsNone(result["line_number"])

    def test_grader_sees_the_image(self):
        models = self.install_grader(marker=CLEAN)
        gemini.grade_working(PNG)
        self.assertIn("image", models.part_kinds(models.last_parts("solver")))

    def test_position_is_normalised_for_the_page(self):
        self.install_grader(marker=FLAG)
        box = gemini.grade_working(PNG)["box"]
        self.assertAlmostEqual(box["y"], 0.20)
        self.assertAlmostEqual(box["x"], 0.10)

    # -- false-accusation protection (the point of this feature) -----------

    def test_a_disputed_flag_is_withdrawn(self):
        # The student used a valid alternative method. The mark must vanish.
        self.install_grader(
            marker=FLAG,
            referee='{"real": false, "reason": "valid alternative method"}')
        result = gemini.grade_working(PNG)
        self.assertEqual(result["verdict"], "correct")
        self.assertIsNone(result["line_number"])
        self.assertEqual(result["reason"], "")

    def test_a_broken_referee_withdraws_the_flag(self):
        # FAIL SAFE, not fail open. Everywhere else in this codebase a broken
        # checker degrades to "ship it"; here it degrades to "say nothing",
        # because the failure being guarded against is accusing the student.
        def boom(contents):
            raise RuntimeError("referee exploded")

        self.install_grader(marker=FLAG, referee=boom)
        result = gemini.grade_working(PNG)
        self.assertEqual(result["verdict"], "correct")
        self.assertIsNone(result["line_number"])

    def test_unparseable_referee_withdraws_the_flag(self):
        self.install_grader(marker=FLAG, referee="not json")
        self.assertEqual(gemini.grade_working(PNG)["verdict"], "correct")

    def test_correct_verdict_is_not_double_checked(self):
        # No claim, nothing to guard against — don't pay for a second call.
        models = self.install_grader(marker=CLEAN)
        gemini.grade_working(PNG)
        self.assertEqual(len(models.of_kind("verifier")), 0)

    def test_confirmed_flag_survives(self):
        self.install_grader(marker=FLAG, referee='{"real": true}')
        self.assertEqual(gemini.grade_working(PNG)["verdict"], "error")

    # -- robustness --------------------------------------------------------

    def test_error_without_a_reason_is_not_shown(self):
        # A vague accusation is worse than none.
        self.install_grader(
            marker='{"verdict": "error", "line_number": 2, "reason": ""}')
        self.assertEqual(gemini.grade_working(PNG)["verdict"], "unreadable")

    def test_unknown_verdict_becomes_unreadable(self):
        self.install_grader(marker='{"verdict": "probably fine"}')
        self.assertEqual(gemini.grade_working(PNG)["verdict"], "unreadable")

    def test_absurd_line_numbers_are_dropped(self):
        for bad in ("0", "-3", "9999", '"two"', "null"):
            self.install_grader(
                marker=f'{{"verdict": "error", "line_number": {bad},'
                       ' "reason": "sign error"}',
                referee='{"real": true}')
            self.assertIsNone(gemini.grade_working(PNG)["line_number"], msg=bad)

    def test_fenced_json_is_parsed(self):
        self.install_grader(marker=f"```json\n{CLEAN}\n```")
        self.assertEqual(gemini.grade_working(PNG)["verdict"], "correct")

    def test_unparseable_marking_is_a_clear_error(self):
        self.install_grader(marker="I cannot read this")
        with self.assertRaises(gemini.GeminiError):
            gemini.grade_working(PNG)

    def test_empty_image_is_rejected(self):
        self.install_grader()
        with self.assertRaises(gemini.GeminiError):
            gemini.grade_working(b"")

    def test_fields_are_bounded(self):
        self.install_grader(
            marker='{"verdict": "error", "line_number": 2,'
                   f' "reason": "{"x" * 900}", "correction": "{"y" * 900}",'
                   f' "problem": "{"z" * 900}"}}',
            referee='{"real": true}')
        result = gemini.grade_working(PNG)
        self.assertLessEqual(len(result["reason"]), 200)
        self.assertLessEqual(len(result["correction"]), 200)
        self.assertLessEqual(len(result["problem"]), 300)


@override_settings(GEMINI_API_KEY="test-key", GEMINI_MODEL="fake-model")
class CheckWorkEndpointTests(GraderHarness, GeminiTestCase):

    def setUp(self):
        super().setUp()
        self.api = APIClient()

    def test_returns_the_marking(self):
        self.install_grader(marker=FLAG, referee='{"real": true}')
        response = self.api.post("/api/check-work/", {"image": _b64(PNG)},
                                 format="json")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["line_number"], 2)

    def test_requires_an_image(self):
        self.install_grader()
        self.assertEqual(
            self.api.post("/api/check-work/", {}, format="json").status_code, 400)


# --------------------------------------------------------------------------
# model routing and cost (PEN-29 / PEN-27)
# --------------------------------------------------------------------------

@override_settings(GEMINI_MODEL="strong-model", GEMINI_FAST_MODEL="cheap-model")
class RoutingTests(SimpleTestCase):
    """
    Downgrade ONLY when the CAS already holds the exact answer. Saving money
    by getting maths wrong is not a saving.
    """

    def test_exact_cas_value_routes_to_the_cheap_model(self):
        route = routing.choose("2+2 =", cas_hint="value: 4")
        self.assertEqual(route.model, "cheap-model")
        self.assertTrue(route.cas_certain)

    def test_exact_value_skips_verification(self):
        # Nothing for a referee to catch: SymPy proved the answer.
        self.assertTrue(routing.choose("2+2 =", cas_hint="value: 4")
                        .skip_verification)

    def test_equations_keep_the_strong_model(self):
        # "solve for x: 2, 3" still needs steps written around it.
        route = routing.choose("x^2-5x+6=0", cas_hint="solve for x: 2, 3")
        self.assertEqual(route.model, "strong-model")
        self.assertFalse(route.skip_verification)

    def test_no_cas_hint_keeps_the_strong_model(self):
        route = routing.choose("two trains leave the station")
        self.assertEqual(route.model, "strong-model")
        self.assertFalse(route.skip_verification)

    def test_images_always_use_the_strong_model(self):
        # Misreading handwriting produces a wrong answer that looks right.
        route = routing.choose("", cas_hint="value: 4", has_image=True)
        self.assertEqual(route.model, "strong-model")
        self.assertFalse(route.skip_verification)

    def test_proofs_always_use_the_strong_model(self):
        route = routing.choose("2+2 =", cas_hint="value: 4",
                               math_detail="proof")
        self.assertEqual(route.model, "strong-model")

    def test_cheap_output_budget_is_smaller(self):
        cheap = routing.choose("2+2 =", cas_hint="value: 4")
        strong = routing.choose("hard one")
        self.assertLess(cheap.max_output_tokens, strong.max_output_tokens)

    @override_settings(GEMINI_FAST_MODEL="")
    def test_without_a_fast_model_nothing_is_downgraded(self):
        # The saving is opt-in — no one gets a quietly weaker answer.
        route = routing.choose("2+2 =", cas_hint="value: 4")
        self.assertEqual(route.model, "strong-model")
        # But verification is still skipped: that's about certainty, not model.
        self.assertTrue(route.skip_verification)


class CASAgreementTests(SimpleTestCase):
    """
    The gate that makes skipping verification safe. A model CAN ignore the
    [CAS] block, and "the model invented an answer" is exactly what the
    referee exists to catch — so the shortcut only applies when the written
    answer demonstrably reproduces the proven value.
    """

    def agrees(self, draft, value):
        return gemini._agrees_with_cas(draft, value)

    def test_matching_answer_agrees(self):
        self.assertTrue(self.agrees("2+2\nAns: 4", "4"))
        self.assertTrue(self.agrees("Ans: 5/6", "5/6"))
        self.assertTrue(self.agrees("Ans: x = 12", "12"))

    def test_substring_numbers_do_not_count(self):
        # "42" must NOT satisfy a proven answer of "4".
        self.assertFalse(self.agrees("Ans: 42", "4"))
        self.assertFalse(self.agrees("Ans: 14", "4"))

    def test_disagreement_is_caught(self):
        self.assertFalse(self.agrees("Ans: 5", "4"))
        self.assertFalse(self.agrees("Ans: 7/8", "5/6"))

    def test_missing_or_empty_input_never_agrees(self):
        # Unclear cases must fall through to the referee, never shortcut.
        for draft, value in (("", "4"), ("Ans: 4", ""), ("", "")):
            self.assertFalse(self.agrees(draft, value))

    def test_uses_the_final_answer_line(self):
        # A working line may mention other numbers; the Ans line decides.
        self.assertTrue(self.agrees("3 + 1 = 9 is wrong\nAns: 4", "4"))
        self.assertFalse(self.agrees("we know 4 is nice\nAns: 9", "4"))


@override_settings(GEMINI_API_KEY="test-key", GEMINI_MODEL="strong-model",
                   GEMINI_FAST_MODEL="cheap-model")
class CASAgreementIntegrationTests(GeminiTestCase):

    def test_agreeing_answer_skips_the_referee(self):
        models = self.install(solver="Ans: 4")
        gemini.generate_reply("2+2 =", capability="mathematician")
        self.assertEqual(len(models.of_kind("verifier")), 0)

    def test_model_ignoring_the_cas_still_gets_refereed(self):
        # The important case: cheap route chosen, but the model wrote
        # something else. The referee must still run.
        models = self.install(solver="Ans: 5")
        gemini.generate_reply("2+2 =", capability="mathematician")
        self.assertEqual(len(models.of_kind("verifier")), 1)


class CostTests(SimpleTestCase):

    def test_cost_scales_with_tokens(self):
        cheap = routing.estimate_cost("gemini-flash-lite", 1000, 1000)
        dear = routing.estimate_cost("gemini-2.5-pro", 1000, 1000)
        self.assertLess(cheap, dear)
        self.assertGreater(cheap, 0)

    def test_usage_extraction_handles_missing_metadata(self):
        class Bare:
            usage_metadata = None
        self.assertEqual(routing.usage_from(Bare()), (0, 0))
        self.assertEqual(routing.usage_from(object()), (0, 0))

    def test_thinking_tokens_are_counted(self):
        # Thinking is billed as output and dominates cost on reasoning models.
        class Meta:
            prompt_token_count = 100
            candidates_token_count = 200
            thoughts_token_count = 500

        class Response:
            usage_metadata = Meta()

        self.assertEqual(routing.usage_from(Response()), (100, 700))


@override_settings(GEMINI_API_KEY="test-key", GEMINI_MODEL="strong-model",
                   GEMINI_FAST_MODEL="cheap-model")
class RoutingIntegrationTests(GeminiTestCase):

    def test_exact_arithmetic_makes_one_call_on_the_cheap_model(self):
        models = self.install(solver="Ans: 4")
        gemini.generate_reply("2+2 =", capability="mathematician")
        self.assertEqual(len(models.calls), 1)          # no verifier pass
        self.assertEqual(models.calls[0][2].__class__.__name__,
                         "GenerateContentConfig")
        self.assertEqual(len(models.of_kind("verifier")), 0)

    def test_harder_problem_still_gets_verified(self):
        models = self.install(solver="Ans: x = 2, 3")
        gemini.generate_reply("x^2-5x+6=0", capability="mathematician")
        self.assertEqual(len(models.of_kind("verifier")), 1)

    def test_cost_is_recorded(self):
        class Meta:
            prompt_token_count = 500
            candidates_token_count = 100
            thoughts_token_count = 0

        def solver(contents):
            return "Ans: 4"

        models = self.install(solver=solver)
        original = models.generate_content

        def with_usage(model, contents, config):
            response = original(model, contents, config)
            response.usage_metadata = Meta()
            return response

        models.generate_content = with_usage
        gemini.generate_reply("2+2 =", capability="mathematician")

        cost = telemetry.snapshot()["cost"]
        self.assertGreater(cost["usd_total"], 0)
        self.assertEqual(cost["prompt_tokens"], 500)


# --------------------------------------------------------------------------
# streaming (PEN-28)
# --------------------------------------------------------------------------

class StreamChunk:
    def __init__(self, text): self.text = text


@override_settings(GEMINI_API_KEY="test-key", GEMINI_MODEL="fake-model",
                   GEMINI_FAST_MODEL="")
class StreamingTests(GeminiTestCase):
    """
    PEN-28. The ordering guarantee is the point: ink cannot be unwritten, so
    a streamed draft must stay provisional until it has been checked.
    """

    def install_stream(self, pieces, verifier='{"verdict": "correct", "reason": "ok"}',
                       corrected="Ans: corrected"):
        models = FakeModels(verifier=verifier)

        def generate_content_stream(model, contents, config):
            return [StreamChunk(p) for p in pieces]

        def generate_content(model, contents, config):
            instruction = config.system_instruction or ""
            kind = "verifier" if "referee" in instruction.lower() else "solver"
            models.calls.append((kind, contents, config))
            if kind == "verifier":
                source = models.verifier
                return FakeResponse(source(contents) if callable(source) else source)
            return FakeResponse(corrected)

        models.generate_content = generate_content
        models.generate_content_stream = generate_content_stream
        patcher = patch.object(gemini, "_client", lambda: FakeClient(models))
        patcher.start()
        self.addCleanup(patcher.stop)
        return models

    def collect(self, **kwargs):
        return list(gemini.stream_math_reply("x^2 = 9 =", **kwargs))

    def test_drafts_arrive_before_the_final(self):
        self.install_stream(["Step one\n", "Step two\n", "Ans: x = ±3"])
        events = self.collect()
        kinds = [e["type"] for e in events]
        self.assertEqual(kinds[-1], "final")
        self.assertGreater(kinds.count("draft"), 1)

    def test_drafts_are_cumulative(self):
        self.install_stream(["Step one\n", "Step two\n", "Ans: 4"])
        drafts = [e["text"] for e in self.collect() if e["type"] == "draft"]
        for earlier, later in zip(drafts, drafts[1:]):
            self.assertTrue(later.startswith(earlier.split("\n")[0]))
        self.assertLess(len(drafts[0]), len(drafts[-1]))

    def test_final_text_matches_the_last_draft_when_correct(self):
        self.install_stream(["Ans: ", "x = ±3"])
        events = self.collect()
        drafts = [e for e in events if e["type"] == "draft"]
        self.assertEqual(events[-1]["text"], drafts[-1]["text"])

    def test_rejected_draft_is_never_marked_final(self):
        # THE guarantee. A draft the referee rejects must arrive as
        # "corrected", so the client replaces the ghost instead of inking it.
        self.install_stream(
            ["Ans: x = 3"],
            verifier='{"verdict": "wrong", "reason": "missed the negative root"}',
            corrected="Ans: x = 3 or x = -3")
        events = self.collect()
        self.assertEqual(events[-1]["type"], "corrected")
        self.assertEqual(events[-1]["text"], "Ans: x = 3 or x = -3")
        self.assertNotIn("final", [e["type"] for e in events])

    def test_verifier_failure_still_finishes(self):
        def boom(contents):
            raise RuntimeError("referee exploded")

        self.install_stream(["Ans: 42"], verifier=boom)
        events = self.collect()
        self.assertEqual(events[-1]["type"], "final")
        self.assertEqual(telemetry.snapshot()["failed_open"], 1)

    def test_stream_failure_reports_an_error(self):
        models = FakeModels()

        def exploding_stream(model, contents, config):
            raise RuntimeError("connection dropped")

        models.generate_content_stream = exploding_stream
        patcher = patch.object(gemini, "_client", lambda: FakeClient(models))
        patcher.start()
        self.addCleanup(patcher.stop)
        events = list(gemini.stream_math_reply("2+2 ="))
        self.assertEqual(events[-1]["type"], "error")

    def test_empty_stream_is_an_error_not_a_blank_final(self):
        self.install_stream([])
        self.assertEqual(self.collect()[-1]["type"], "error")

    def test_empty_message_is_rejected(self):
        self.install_stream(["Ans: 4"])
        events = list(gemini.stream_math_reply("   "))
        self.assertEqual(events[0]["type"], "error")

    def test_exact_cas_answer_skips_the_referee(self):
        models = self.install_stream(["Ans: 4"])
        events = list(gemini.stream_math_reply("2+2 ="))
        self.assertEqual(events[-1]["type"], "final")
        self.assertEqual(len(models.of_kind("verifier")), 0)


@override_settings(GEMINI_API_KEY="test-key", GEMINI_MODEL="fake-model")
class StreamEndpointTests(GeminiTestCase):

    def setUp(self):
        super().setUp()
        self.api = APIClient()

    def test_emits_server_sent_events(self):
        models = FakeModels(verifier='{"verdict": "correct", "reason": "ok"}')
        models.generate_content_stream = (
            lambda model, contents, config: [StreamChunk("Ans: 4")])
        patcher = patch.object(gemini, "_client", lambda: FakeClient(models))
        patcher.start()
        self.addCleanup(patcher.stop)

        response = self.api.post("/api/solve-stream/", {"message": "2+2 ="},
                                 format="json")
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response["Content-Type"].startswith("text/event-stream"))
        body = b"".join(response.streaming_content).decode()
        self.assertIn("data: ", body)
        self.assertIn('"type": "final"', body)

    def test_requires_a_message(self):
        self.install()
        self.assertEqual(
            self.api.post("/api/solve-stream/", {}, format="json").status_code, 400)


# --------------------------------------------------------------------------
# access control (PEN-26)
# --------------------------------------------------------------------------

TOKEN = "test-token-abc123"


@override_settings(GEMINI_API_KEY="test-key", GEMINI_MODEL="fake-model",
                   PENPAL_TOKENS={TOKEN},
                   RATE_LIMIT_PER_MINUTE=5, RATE_LIMIT_PER_DAY=20)
class AccessControlTests(GeminiTestCase):
    """
    The risk is a bill, not a breach: this server spends a Gemini key on
    request and was previously reachable by anyone on the network.
    """

    def setUp(self):
        super().setUp()
        access.reset()
        self.addCleanup(access.reset)
        self.api = APIClient()
        self.install()

    def post(self, token=None, header="HTTP_AUTHORIZATION", value=None):
        extra = {}
        if token:
            extra[header] = value or f"Bearer {token}"
        return self.api.post("/api/chat/", {"message": "hi"},
                             format="json", **extra)

    # -- authentication ----------------------------------------------------

    def test_request_without_a_token_is_rejected(self):
        self.assertEqual(self.post().status_code, 401)

    def test_request_with_a_wrong_token_is_rejected(self):
        self.assertEqual(self.post("wrong-token").status_code, 401)

    def test_valid_bearer_token_is_accepted(self):
        self.assertEqual(self.post(TOKEN).status_code, 200)

    def test_x_penpal_token_header_also_works(self):
        response = self.post(TOKEN, header="HTTP_X_PENPAL_TOKEN", value=TOKEN)
        self.assertEqual(response.status_code, 200)

    def test_token_prefix_is_not_accepted(self):
        # Guards against a truncated/prefix comparison being treated as valid.
        self.assertEqual(self.post(TOKEN[:-1]).status_code, 401)

    def test_all_expensive_endpoints_are_protected(self):
        for path, body in (("/api/chat/", {"message": "hi"}),
                           ("/api/solve-math/", {"image": _b64(PNG)}),
                           ("/api/read-math/", {"image": _b64(PNG)})):
            response = self.api.post(path, body, format="json")
            self.assertEqual(response.status_code, 401, msg=path)

    def test_health_stays_open(self):
        # Liveness must work without a token or monitoring can't see the box.
        self.assertEqual(self.api.get("/api/health/").status_code, 200)

    # -- rate limiting -----------------------------------------------------

    def test_per_minute_limit(self):
        for i in range(5):
            self.assertEqual(self.post(TOKEN).status_code, 200, msg=i)
        limited = self.post(TOKEN)
        self.assertEqual(limited.status_code, 429)
        self.assertIn("Retry-After", limited)

    def test_daily_limit(self):
        with override_settings(RATE_LIMIT_PER_MINUTE=10_000,
                               RATE_LIMIT_PER_DAY=3):
            for _ in range(3):
                self.assertEqual(self.post(TOKEN).status_code, 200)
            self.assertEqual(self.post(TOKEN).status_code, 429)

    def test_limits_are_per_token(self):
        # One noisy device must not lock out another.
        with override_settings(PENPAL_TOKENS={TOKEN, "second-token"},
                               RATE_LIMIT_PER_MINUTE=2):
            for _ in range(2):
                self.post(TOKEN)
            self.assertEqual(self.post(TOKEN).status_code, 429)
            self.assertEqual(self.post("second-token").status_code, 200)

    def test_rejected_requests_do_not_consume_quota(self):
        for _ in range(10):
            self.post("wrong-token")
        self.assertEqual(self.post(TOKEN).status_code, 200)


@override_settings(GEMINI_API_KEY="test-key", GEMINI_MODEL="fake-model",
                   PENPAL_TOKENS=set())
class DevModeTests(GeminiTestCase):
    """With no tokens configured (dev mode) the API stays frictionless."""

    def test_open_when_no_tokens_configured(self):
        self.install()
        response = APIClient().post("/api/chat/", {"message": "hi"},
                                    format="json")
        self.assertEqual(response.status_code, 200)
