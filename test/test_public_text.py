"""dev/public-text-check: the company's rules for public text, with a bad and a
good example of every class, so a pattern that stops matching or starts to
match a product word fails the build.

The examples are written for the test: no real pull request, person or device."""

import base64
import importlib.machinery
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
SCRIPT = os.path.join(ROOT, "dev", "public-text-check")

_loader = importlib.machinery.SourceFileLoader("public_text_check", SCRIPT)
_spec = importlib.util.spec_from_loader("public_text_check", _loader)
ptc = importlib.util.module_from_spec(_spec)
_loader.exec_module(ptc)

RULES = ptc.load_rules()
ENV, OPEN, UNLINKED = (RULES[k]["check"] for k in ("environment", "open_item", "unlinked_reference"))


def problems(text, files=()):
    """[(check, rule id)] of one text."""
    return [(check, rule) for check, rule, _ in ptc.check_text(RULES, text, files)]


def checks(text, files=()):
    return {check for check, _ in problems(text, files)}


class Environment(unittest.TestCase):
    BAD = {
        "sandbox-tool": "Checked with dev/sandbox on this head.",
        "sandbox": "Everything passes in the sandbox.",
        "rig": "The rig check is clean.",
        "emulator": "The emulator cannot judge this.",
        "podman": "A podman run of the suite is green.",
        "container": "Started a container and opened the panel.",
        "paperclip": "Tracked on the Paperclip board.",
        "task-id": "Task SCE-123 has the details.",
        "home-path": "Logs are in /home/someone/logs.",
        "dot-path": "The state is under ~/.config/thing.",
        "tmp-path": "Output in /tmp/run-1/out.txt.",
        "runtime-dir": "Stills in $XDG_RUNTIME_DIR/other/.",
        "test-count-passed": "92 passed, 0 failed.",
        "test-count": "The suite ran 380 tests.",
        "test-tally": "76 pass, 0 fail.",
        "own-machine": "It works on this machine.",
    }

    def test_every_class_fails(self):
        for rule, text in self.BAD.items():
            with self.subTest(rule=rule):
                self.assertIn((ENV, rule), problems(text))

    def test_every_pattern_has_a_bad_example(self):
        self.assertEqual({p["id"] for p in RULES["environment"]["patterns"]}, set(self.BAD))

    def test_product_words_pass(self):
        for text in [
            "The panel lists the Paperclip inbox; an agent's run shows its status.",
            "Paperclip tokens are kept in the plugin's own file.",
            "A picture is decoded in a sandbox, never by the shell.",
            "Thumbnails are decoded in a sandbox with no network.",
            "Pictures are decoded only in a sandbox, never by the shell.",
            "Decoding happens in the sandbox.",
            "Decoding runs in a sandbox with no network.",
            "Each image is decoded within its own sandbox.",
            "The skills are in `~/.config/omarchy/paperclipai/skills` and stills live in $XDG_RUNTIME_DIR/sceny.paperclipai/.",
            "The QML container item keeps the row's width.",
            "The container keeps its width.",
            "Adds 3 tests for the new key. Counts are in test/test_model.mjs.",
            "Adds 4 new tests and writes 2 more tests for the fold.",
            "Pictures are decoded with glycin in a sandbox, then drawn.",
            "See [the tool](https://github.com/sceny/omarchy-paperclipai/blob/main/dev/rig) for how it works.",
            "```\ndev/rig up\n```",
        ]:
            with self.subTest(text=text):
                self.assertEqual(problems(text), [])

    def test_a_pull_request_about_a_tool_may_name_it(self):
        text = "dev/sandbox now takes --session; the rig starts in the container."
        self.assertIn(ENV, checks(text))
        self.assertNotIn(ENV, checks(text, ["dev/sandbox", "dev/sandbox.d/x"]))
        self.assertIn(ENV, checks("Task SCE-1", ["dev/sandbox"]))

    def test_the_rules_own_pull_request_may_quote_the_words(self):
        text = "It never holds the sandbox, the rig, an emulator or SCE-5."
        self.assertIn(ENV, checks(text))
        for rules_file in ("dev/public-text-check", "dev/public-text-rules.json", "test/test_public_text.py"):
            with self.subTest(file=rules_file):
                self.assertEqual(checks(text, [rules_file]), set())

    def test_the_rules_own_pull_request_may_not_name_anything_else(self):
        files = ["dev/public-text-rules.json"]
        for rule, text in [
            ("home-path", "Logs are in /home/someone/logs."),
            ("dot-path", "The state is under ~/.config/thing."),
            ("tmp-path", "Output in /tmp/run-1/out.txt."),
            ("runtime-dir", "Stills in $XDG_RUNTIME_DIR/other/."),
            ("test-count-passed", "92 passed, 0 failed."),
            ("test-count", "The suite ran 380 tests."),
            ("test-tally", "76 pass, 0 fail."),
        ]:
            with self.subTest(rule=rule):
                self.assertIn((ENV, rule), problems(text, files))

    def test_the_sandbox_and_the_container_are_exempt_only_in_the_sentence_that_needs_them(self):
        for rule, text in [
            ("sandbox", "Verified in the sandbox: the picture matches."),
            ("sandbox", "The image is fine; verified in the sandbox."),
            ("sandbox", "Thumbnails look right. Checked in the sandbox."),
            ("sandbox", "Pictures are decoded; the panel was checked in the sandbox."),
            ("container", "Ran the checks in a container; the QML item is fine."),
            ("container", "The row is fine - ran it in a container."),
            ("container", "Started a container and opened the panel."),
            ("sandbox", "The thumbnails are decoded, the picture looks right and the panel was checked in the sandbox."),
            ("container", "The layout of the panel was fine and we checked all of it in a container."),
            ("sandbox", "Ran the suite in the sandbox, which decodes the picture."),
            ("sandbox", "Verified: decoded images look right in the sandbox."),
            ("sandbox", "Checked in the sandbox that images decode."),
            ("sandbox", "Thumbnails are decoded, and the panel was checked in the sandbox."),
        ]:
            with self.subTest(text=text):
                self.assertIn((ENV, rule), problems(text))
        for text in [
            "Pictures are decoded in a sandbox. The panel loads them.",
            "A file with no recorded type is sent around the sandbox.",
            "A picture is not opened with no sandbox.",
            "The QML item is placed in a container row.",
            "Thumbnails are decoded in the sandbox before the shell loads them.",
            "Every layout runs inside a container item.",
            "Pictures are decoded in the sandbox, and the panel loads them.",
        ]:
            with self.subTest(text=text):
                self.assertEqual(problems(text), [])

    def test_a_container_that_is_not_the_place_we_ran_in_passes(self):
        for text in [
            "The container keeps its width.",
            "A container for the pinned row grows with its content.",
            "Containers hold the shortcuts.",
            "Creates a container for the cards.",
            "Creates a container for the tiles and the grid.",
        ]:
            with self.subTest(text=text):
                self.assertEqual(problems(text), [])
        for text in [
            "Ran it inside a rootless container.",
            "A fresh container per run.",
            "The container image is rebuilt.",
            "Creates a container from the image.",
        ]:
            with self.subTest(text=text):
                self.assertIn((ENV, "container"), problems(text))

    def test_a_count_of_tests_a_change_adds_is_not_a_run(self):
        for text in [
            "Adds 3 tests.",
            "Added 12 new tests for the key.",
            "Includes 2 tests for the order.",
            "Adds 3 tests and writes 2 tests.",
        ]:
            with self.subTest(text=text):
                self.assertEqual(problems(text), [])
        for text in [
            "Adds a case. The suite ran 380 tests.",
            "Adds 3 tests; 380 tests pass.",
            "Adds 3 tests, 92 passed.",
            "We add 3 tests and 92 tests pass.",
            "Adds 3 tests and 92 tests pass.",
        ]:
            with self.subTest(text=text):
                self.assertTrue(checks(text), text)


    def test_html_comments_are_read_and_fences_stay_blank(self):
        for rule, text in [
            ("task-id", "Clean body.\n<!-- SCE-123 -->"),
            ("paperclip", "<!--\nfrom the paperclip board\n-->\nClean."),
            ("own-machine", "Fine. <!-- checked on this machine --> Fine."),
        ]:
            with self.subTest(text=text):
                self.assertIn((ENV, rule), problems(text))
        for text in [
            "Clean.\n<!-- session:panel-qa -->",
            "```\n<!-- SCE-1 -->\n```",
            "<!-- TODO: nothing here is a leftover -->",
        ]:
            with self.subTest(text=text):
                self.assertEqual(problems(text), [])

    def test_a_tally_of_passes_and_failures_fails(self):
        for text in [
            "76 pass, 0 fail.",
            "Result: 12 pass.",
            "3 fail on the old head.",
            "92 passed, 1 failed.",
            "2 failures, both fixed.",
            "40 tests pass.",
        ]:
            with self.subTest(text=text):
                self.assertTrue({"test-tally", "test-count-passed"} & {r for _, r in problems(text)}, text)
        for text in [
            "A fail-safe stops it at 1 fail-over.",
            "The second pass reads the cache.",
            "It fails when the key is missing.",
            "The panel stops after 3 failed pairings.",
            "After 2 failures in a row the bridge waits.",
            "Version 2 failed to load the panel.",
            "Android 13 failed to duplicate the audio.",
            "Step 3 failed without the key.",
        ]:
            with self.subTest(text=text):
                self.assertEqual(problems(text), [])

    def test_this_machine_and_the_host_fail_and_a_product_host_passes(self):
        for text in [
            "Checked on this machine.",
            "It runs on this host with no network.",
            "The host has no Android device.",
            "Ran it on the host, then pushed.",
        ]:
            with self.subTest(text=text):
                self.assertIn((ENV, "own-machine"), problems(text))
        for text in [
            "The host name comes from mDNS.",
            "The host's name is shown on the card.",
            "The device's address and the host in its URL are kept.",
            "The host-side check reads the key.",
            "This computer keeps the clipboard.",
            "Keys are read from Hyprland on this machine, never assumed.",
            "The firewall rule opens the port on this machine only.",
        ]:
            with self.subTest(text=text):
                self.assertEqual(problems(text), [])

    def test_a_rig_or_sandbox_change_may_name_the_host(self):
        text = "The rig never writes the host plugin folder."
        self.assertIn((ENV, "own-machine"), problems(text))
        for files in (["dev/rig"], ["dev/sandbox"], ["docs/internals/development.md"], ["test/test_sandbox.py"]):
            with self.subTest(files=files):
                self.assertEqual(problems(text, files), [])
        self.assertIn((ENV, "own-machine"), problems(text, ["Model.js"]))


class OpenItems(unittest.TestCase):
    def test_bad(self):
        for text in [
            "Not checked in the panel.",
            "The reconnect path was not tested.",
            "The edge is untested.",
            "Left for later.",
            "A follow-up covers the fold.",
            "We can do it later.",
            "I will look at it later and decide then.",
            "Looked at it later, no change.",
            "Fix this later, once the key exists.",
            "Handled in a later release.",
            "TODO: the second page.",
            "Out of scope here.",
            "- Fine.\n- The fold is not covered.\n- Fine too.",
            "Verdict: pass.\n\nNot blocking, for later: the ellipsis re-flows.",
            "Tracked separately, in the next release.",
            "The fold is tracked on its own issue.",
            "Still to write the fold test.",
            "Note, does not block: the ellipsis re-flows.",
            "This does not block the merge; the label moves.",
            "Non-blocking: the label moves by a pixel.",
            "One non-blocking note on the fold.",
            "(not blocking) The label moves.",
            "Nit, non-blocking: the label moves.",
            "- **Non-blocking:** the label moves.",
            "The label moves in a separate change.",
            "A separate pull request takes the fold.",
            "Left for the panel engineer.",
            "The fold is left for a later release.",
        ]:
            with self.subTest(text=text):
                self.assertIn(OPEN, checks(text))

    def test_a_reference_in_the_same_bullet_or_paragraph_passes(self):
        for text in [
            "Not blocking, for later: the ellipsis re-flows (#246).",
            "A follow-up is tracked in sceny/omarchy-paperclipai#246.",
            "- The fold is not covered: https://github.com/sceny/omarchy-paperclipai/issues/12",
            "Not checked in the panel.\nIt is tracked in #9.",
            "- Left for later\n  - the ellipsis (#4)",
        ]:
            with self.subTest(text=text):
                self.assertNotIn(OPEN, checks(text))

    def test_a_review_note_with_its_issue_passes(self):
        for text in [
            "Note, does not block: the ellipsis re-flows (#246).",
            "Non-blocking: the label moves, tracked in sceny/omarchy-paperclipai#12.",
            "The label moves in a separate change, #31.",
            "Left for the panel engineer in #40.",
        ]:
            with self.subTest(text=text):
                self.assertNotIn(OPEN, checks(text))

    def test_product_words_near_a_review_note_pass(self):
        for text in [
            "A reader that never reads does not block the shell.",
            "A non-blocking read of the clipboard, cut at a byte limit.",
            "The room left for the title shrinks as the chip grows.",
            "The step left for the user shows under the switch.",
            "Each device keeps a separate cache.",
            "The write does not block, so the bar keeps drawing.",
            "A reader that never reads does not block it.",
            "The clipboard read is now non-blocking.",
            "wl-paste runs non-blocking: the shell never waits.",
            "The rename is in a separate commit, so the diff reads.",
        ]:
            with self.subTest(text=text):
                self.assertNotIn(OPEN, checks(text))

    def test_a_reference_in_another_bullet_does_not_count(self):
        self.assertIn(OPEN, checks("- Not tested here.\n- Another thing (#7)."))

    def test_a_lead_line_asks_it_of_the_bullets_under_it(self):
        self.assertEqual(checks("**Not checked:**\n\n- the fold (#1)\n- the page (#2)"), set())
        text = "**Not checked:**\n\n- the fold (#1)\n- the page"
        self.assertEqual(len([p for p in problems(text) if p[0] == OPEN]), 1)
        self.assertIn(OPEN, checks("## Follow-ups\n\n- the page"))
        self.assertNotIn(OPEN, checks("## Follow-ups\n\n- the page (#3)"))

    def test_a_stated_gap_passes_and_a_bare_not_checked_does_not(self):
        self.assertNotIn(OPEN, checks("- Not verified: iOS (needs macOS)."))
        self.assertNotIn(OPEN, checks("Not verified: iOS, no Mac here."))
        self.assertNotIn(OPEN, checks("1. Not verified: iOS."))
        self.assertNotIn(OPEN, checks("2) Not verified: iOS."))
        self.assertNotIn(OPEN, checks("**Not verified:** iOS."))
        self.assertNotIn(OPEN, checks("> Not verified: iOS."))
        self.assertNotIn(OPEN, checks("- [ ] Not verified: iOS."))
        self.assertNotIn(OPEN, checks("- **Not verified:** iOS, no Mac here."))
        self.assertIn(OPEN, checks("- Not checked on iOS."))
        self.assertIn(OPEN, checks("**Not verified:** iOS. Not checked on Android."))
        self.assertIn(OPEN, checks("- [ ] Not verified: iOS. Not tested on Android."))
        self.assertIn(OPEN, checks("Not verified: iOS. Not checked on Android."))
        self.assertIn(OPEN, checks("NOT VERIFIED: iOS, but not checked on Android."))
        self.assertIn(OPEN, checks("Not checked in a running shell, and not tested."))

    def test_a_quoted_or_nested_stated_gap_passes(self):
        for text in [
            "> Not verified: iOS.",
            "> - Not verified: iOS.",
            "> > Not verified: iOS.",
            "- > Not verified: iOS.",
            "- - Not verified: iOS.",
            "1. - Not verified: iOS.",
            "> 1. - Not verified: iOS.",
        ]:
            with self.subTest(text=text):
                self.assertNotIn(OPEN, checks(text))
        self.assertIn(OPEN, checks("> Not checked on iOS."))
        self.assertIn(OPEN, checks("> - Not checked on iOS."))
        self.assertIn(OPEN, checks("- > - Not checked on iOS."))

    def test_words_that_are_not_a_leftover_pass(self):
        for text in [
            "A later change keeps the old keys.",
            "The next read 10 s later, because a doctor read was dropped.",
            "The later head is read again.",
            "Not checked in a running shell: the merge waits for someone to check it there.",
            "All of it is checked.",
            "`TODO` in code is shown as code.",
            "```\n# TODO later\n```",
        ]:
            with self.subTest(text=text):
                self.assertNotIn(OPEN, checks(text))


class UnlinkedReferences(unittest.TestCase):
    def test_bad(self):
        for text, rule in [
            ("Upstream is omarchy#8753.", "repo-without-owner"),
            ("See kdeconnect-kde#99 for the fault.", "repo-without-owner"),
            ("It is the marketplace's #10096.", "named-upstream-bare-number"),
            ("Reported upstream #42.", "named-upstream-bare-number"),
            ("KDE Connect #7 has the report.", "named-upstream-bare-number"),
            ("See ab#12.", "repo-without-owner"),
            ("Filed as `sceny/omarchy-paperclipai`: #550.", "repo-without-owner"),
            ("Filed as `sceny/omarchy-paperclipai` #550.", "repo-without-owner"),
            ("Filed in sceny/omarchy-paperclipai: #550 and #551.", "repo-without-owner"),
        ]:
            with self.subTest(text=text):
                self.assertIn((UNLINKED, rule), problems(text))

    def test_good(self):
        for text in [
            "Upstream is omacom/omarchy#8753.",
            "Tracked in [sceny/omarchy-paperclipai#246](https://github.com/sceny/omarchy-paperclipai/issues/246).",
            "This repository's own #195 and #194 stay bare.",
            "See https://github.com/omacom/omarchy/issues/8753#issuecomment-1 and docs/x.md#12.",
            "Inline `omarchy#8753` is code.",
            "The C#5 sample compiles.",
            "Filed as sceny/omarchy-paperclipai#550.",
            "The rule lives in `dev/public-text-rules.json` (#12).",
            "Read `docs/setup.md`: it says what #12 changed.",
        ]:
            with self.subTest(text=text):
                self.assertNotIn(UNLINKED, checks(text))


class WholePullRequest(unittest.TestCase):
    def doc(self, *bodies, files=()):
        return {"changed_files": list(files), "texts": [
            {"url": "https://example.test/c/%d" % i, "body": body} for i, body in enumerate(bodies)]}

    def test_only_the_body_and_the_commits_quote_the_rules_words(self):
        text = "It never holds the rig or SCE-5."
        files = ["dev/public-text-rules.json"]
        for kind in ("body", "commit"):
            with self.subTest(kind=kind):
                doc = {"changed_files": files, "texts": [{"url": "u", "body": text, "kind": kind}]}
                self.assertEqual(ptc.check_pull_request(RULES, doc), [])
        for kind in ("title", "comment", "review", "review-comment", None):
            with self.subTest(kind=kind):
                doc = {"changed_files": files, "texts": [{"url": "u", "body": text, "kind": kind}]}
                self.assertIn(ENV, {c for _, c, _, _ in ptc.check_pull_request(RULES, doc)})

    def test_every_kind_of_text_is_read_and_named_by_its_url(self):
        found = ptc.check_pull_request(RULES, self.doc("Clean.", "Ran it in the rig.", None, "Not tested."))
        self.assertEqual([(url, check) for url, check, _, _ in found],
                         [("https://example.test/c/1", ENV), ("https://example.test/c/3", OPEN)])

    def test_a_clean_pull_request_passes(self):
        self.assertEqual(ptc.check_pull_request(RULES, self.doc("Adds a button for #194.", "Pass. Checked the fold.")), [])

    def run_cli(self, doc, ci=False, extra=()):
        env = {k: v for k, v in os.environ.items() if k != "GITHUB_ACTIONS"}
        if ci:
            env["GITHUB_ACTIONS"] = "true"
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump(doc, handle)
        try:
            return subprocess.run([sys.executable, SCRIPT, "--fixture", handle.name, *extra],
                                  capture_output=True, text=True, env=env)
        finally:
            os.unlink(handle.name)

    def test_in_ci_a_failure_names_the_rule_and_not_the_match(self):
        result = self.run_cli(self.doc("Logs are in /home/someone/logs."), ci=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL public-text-environment [home-path] https://example.test/c/0", result.stdout)
        self.assertNotIn("someone", result.stdout)

    def test_show_matches_prints_the_match_in_ci(self):
        result = self.run_cli(self.doc("Logs are in /home/someone/logs."), ci=True, extra=["--show-matches"])
        self.assertIn("someone", result.stdout)

    def test_exit_codes_and_output(self):
        self.assertEqual(self.run_cli(self.doc("Fine.")).returncode, 0)
        long = "word " * 200 + "Verified in the sandbox. " + "tail " * 200
        result = self.run_cli(self.doc(long))
        self.assertEqual(result.returncode, 1)
        self.assertIn("public-text-environment", result.stdout)
        self.assertIn("https://example.test/c/0", result.stdout)
        self.assertIn("sandbox", result.stdout)
        self.assertNotIn("tail tail", result.stdout)
        self.assertLess(len(result.stdout), 400)

    def test_every_class_fails_the_command(self):
        examples = {ENV: "Ran it in the rig.", OPEN: "Not checked in the panel.", UNLINKED: "Upstream is omarchy#8753."}
        for check, text in examples.items():
            with self.subTest(check=check):
                result = self.run_cli(self.doc(text))
                self.assertEqual(result.returncode, 1)
                self.assertIn(check, result.stdout)

    def test_output_has_no_control_characters_or_workflow_commands(self):
        evil = "::error::x\r\nSCE-1\x1b[31m"
        result = self.run_cli(self.doc(evil))
        for line in result.stdout.split("\n"):
            self.assertFalse(line.startswith("::"), line)
        self.assertNotIn("\x1b", result.stdout)
        self.assertNotIn("\r", result.stdout)

    def test_unreadable_input_is_not_a_pass(self):
        env = {k: v for k, v in os.environ.items() if k not in ("GITHUB_TOKEN", "GH_TOKEN", "GITHUB_EVENT_PATH")}
        result = subprocess.run([sys.executable, SCRIPT], capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 2)


class Sources(unittest.TestCase):
    """Where the texts come from: a pull request's title and commits, a comment on it, and a push to develop."""
    REPO = "sceny/omarchy-paperclipai"
    URL = "https://github.com/sceny/omarchy-paperclipai/pull/258"
    TITLE = "Sandbox: one image per repository on a common base; omarchy-paperclipai and dev/soak run in it (SCE-741)"
    SQUASH = "All 94 tests pass. HUP signal now fires immediately when caught in any backgrounded pipeline."
    COMMIT_URL = "https://github.com/sceny/omarchy-paperclipai/commit/da23a05"
    PR = {"html_url": URL, "title": TITLE, "body": "Clean body.", "number": 258, "state": "open", "updated_at": "2026-10-17T00:19:37Z"}

    def fake_api(self, responses):
        def api(path, token):
            key = path.split("?")[0]
            return responses.get(key, [])
        return api

    def read(self, responses, commits=True):
        with mock.patch.object(ptc, "api", self.fake_api(responses)):
            return ptc.read_pull_request(self.REPO, 258, "token", commits=commits)

    def test_each_text_carries_its_kind(self):
        review = {"html_url": self.URL + "#pullrequestreview-1", "body": "Pass."}
        doc = self.read({
            "/repos/%s/pulls/258" % self.REPO: self.PR,
            "/repos/%s/pulls/258/commits" % self.REPO: [{"html_url": self.COMMIT_URL, "commit": {"message": "Clean."}}],
            "/repos/%s/issues/258/comments" % self.REPO: [{"html_url": self.URL + "#issuecomment-1", "body": "Ok."}],
            "/repos/%s/pulls/258/reviews" % self.REPO: [review],
            "/repos/%s/pulls/258/comments" % self.REPO: [{"html_url": self.URL + "#discussion_r1", "body": "Nit."}],
        })
        self.assertEqual([t["kind"] for t in doc["texts"]], ["title", "body", "commit", "comment", "review", "review-comment"])

    def test_the_title_is_read_and_its_task_id_fails(self):
        doc = self.read({"/repos/%s/pulls/258" % self.REPO: self.PR})
        self.assertIn({"url": self.URL, "body": self.TITLE, "kind": "title"}, doc["texts"])
        self.assertIn((ENV, "task-id"), checks_of(doc))

    def test_the_commit_messages_of_a_pull_request_are_read(self):
        responses = {
            "/repos/%s/pulls/258" % self.REPO: self.PR,
            "/repos/%s/pulls/258/commits" % self.REPO: [{"html_url": self.COMMIT_URL, "commit": {"message": self.SQUASH}}],
        }
        doc = self.read(responses)
        self.assertIn({"url": self.COMMIT_URL, "body": self.SQUASH, "kind": "commit"}, doc["texts"])
        self.assertIn((ENV, "test-count"), checks_of(doc))

    def test_a_comment_on_a_closed_pull_request_does_not_reread_its_commits(self):
        responses = {
            "/repos/%s/pulls/258" % self.REPO: dict(self.PR, state="closed"),
            "/repos/%s/pulls/258/commits" % self.REPO: [{"html_url": self.COMMIT_URL, "commit": {"message": self.SQUASH}}],
        }
        doc = self.read(responses)
        self.assertIn({"url": self.URL, "body": self.TITLE, "kind": "title"}, doc["texts"])
        self.assertNotIn(self.COMMIT_URL, [text["url"] for text in doc["texts"]])
        self.assertNotIn((ENV, "test-count"), checks_of(doc))

    def test_a_push_to_develop_reads_the_commit_message_that_lands(self):
        responses = {
            "/repos/%s/compare/aaa...bbb" % self.REPO: {"commits": [{"sha": "ccc", "html_url": self.COMMIT_URL, "commit": {"message": self.SQUASH}}]},
            "/repos/%s/commits/aaa" % self.REPO: {"commit": {"committer": {"date": "2026-10-22T00:00:00Z"}}},
            "/repos/%s/pulls" % self.REPO: [],
        }
        texts, _, docs = self.push(responses)
        self.assertEqual(texts, [{"url": self.COMMIT_URL, "body": self.SQUASH, "kind": "commit"}])
        self.assertEqual(docs, [])

    def test_a_push_to_develop_reads_the_comments_on_the_pull_request_it_merged(self):
        merged = dict(self.PR, number=356, state="closed", merged_at="2026-10-23T09:00:00Z", merge_commit_sha="sss",
                      html_url="https://github.com/sceny/omarchy-paperclipai/pull/356")
        comment = {"html_url": "https://github.com/sceny/omarchy-paperclipai/pull/356#issuecomment-1", "body": "Not checked on the phone."}
        responses = {
            "/repos/%s/compare/aaa...bbb" % self.REPO: {"commits": [{"sha": "sss", "html_url": self.COMMIT_URL, "commit": {"message": "Clean."}}]},
            "/repos/%s/commits/sss/pulls" % self.REPO: [merged],
            "/repos/%s/pulls/356" % self.REPO: merged,
            "/repos/%s/issues/356/comments" % self.REPO: [comment],
        }
        _, _, docs = self.push(responses)
        self.assertEqual([doc["texts"][0]["url"] for doc in docs], [merged["html_url"]])
        self.assertIn((comment["html_url"], OPEN, "not-checked"),
                      [(url, c, r) for url, c, r, _ in ptc.check_pull_request(RULES, docs[0])])

    def test_a_push_to_develop_does_not_read_a_pull_request_it_did_not_merge(self):
        # An open pull request updated after the commit before the push, and one that
        # carries a commit of the push but was merged by another: neither is this push's.
        bad = "Not checked on the phone."
        opened = dict(self.PR, number=901, state="open", merged_at=None, merge_commit_sha="ooo", body=bad,
                      updated_at="2026-10-23T09:00:00Z", html_url="https://github.com/sceny/omarchy-paperclipai/pull/901")
        earlier = dict(self.PR, number=902, state="closed", merged_at="2026-10-01T00:00:00Z", merge_commit_sha="eee", body=bad,
                       updated_at="2026-10-23T09:00:00Z", html_url="https://github.com/sceny/omarchy-paperclipai/pull/902")
        responses = {
            "/repos/%s/compare/aaa...bbb" % self.REPO: {"commits": [{"sha": "sss", "html_url": self.COMMIT_URL, "commit": {"message": "Clean."}}]},
            "/repos/%s/commits/aaa" % self.REPO: {"commit": {"committer": {"date": "2026-10-22T00:00:00Z"}}},
            "/repos/%s/commits/sss/pulls" % self.REPO: [opened, earlier],
            "/repos/%s/pulls" % self.REPO: [opened, earlier],
            "/repos/%s/pulls/901" % self.REPO: opened,
            "/repos/%s/pulls/902" % self.REPO: earlier,
        }
        _, _, docs = self.push(responses)
        self.assertEqual(docs, [])

    def push(self, responses):
        with mock.patch.object(ptc, "api", self.fake_api(responses)):
            return ptc.read_push(self.REPO, "aaa", "bbb", "token")

    def test_a_comment_on_a_pull_request_names_its_number(self):
        self.assertEqual(ptc.pull_request_number({"issue": {"number": 301, "pull_request": {"url": "x"}}}), 301)
        self.assertEqual(ptc.pull_request_number({"pull_request": {"number": 7}}), 7)
        self.assertIsNone(ptc.pull_request_number({"issue": {"number": 12}}))

    def test_a_merge_group_names_the_pull_request_it_merges(self):
        group = {"merge_group": {"head_ref": "refs/heads/gh-readonly-queue/develop/pr-85-3aa9ef0787f1b1177f2f54d903fc25830f147f35"}}
        self.assertEqual(ptc.pull_request_number(group), 85)
        self.assertIsNone(ptc.pull_request_number({"merge_group": {"head_ref": "refs/heads/develop"}}))


def checks_of(doc):
    return {(check, rule) for _, check, rule, _ in ptc.check_pull_request(RULES, doc)}


class Standing(unittest.TestCase):
    def test_the_standing_texts_pass(self):
        found = ptc.check_standing(RULES)
        self.assertEqual(found, [], "\n".join("%s %s %s" % (w, r, m) for w, _, r, m in found))

    def test_history_in_a_standing_text_fails(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "docs", "internals"))
            with open(os.path.join(root, "AGENTS.md"), "w") as handle:
                handle.write("A rule.\nThe owner decided it on 2026-01-02 (SCE-12).\nThe owner asked for it.\n"
                             "Done when the owner said go for that SHA.\n```\nSCE-9 in code\n```\n")
            found = ptc.check_standing(RULES, root)
            self.assertEqual(sorted((w, r) for w, _, r, _ in found),
                             [("AGENTS.md:2", "date-as-history"), ("AGENTS.md:2", "owner-said"),
                              ("AGENTS.md:2", "task-id"), ("AGENTS.md:3", "owner-said")])

    def test_a_standing_text_names_another_repository_s_issue_so_it_links(self):
        with tempfile.TemporaryDirectory() as root:
            with open(os.path.join(root, "AGENTS.md"), "w") as handle:
                handle.write("Fixed in sceny/omarchy-paperclipai#550.\nFiled as `sceny/omarchy-paperclipai`: #551.\n<!-- SCE-9 -->\n")
            found = ptc.check_standing(RULES, root)
            self.assertEqual(sorted((w, r) for w, _, r, _ in found),
                             [("AGENTS.md:2", "repo-without-owner"), ("AGENTS.md:3", "task-id")])


class PublicFiles(unittest.TestCase):
    def check_release_notes(self, text):
        with tempfile.TemporaryDirectory() as root:
            with open(os.path.join(root, "CHANGELOG.md"), "w") as handle:
                handle.write(text)
            return [(where, rule) for where, _, rule, _ in ptc.check_public_files(RULES, root)]

    def test_a_release_note_line_with_a_task_id_fails(self):
        self.assertEqual(self.check_release_notes("## 1.0.0\n\n- Fixed the fold (#12).\n- Copied from a title (SCE-123).\n"),
                         [("CHANGELOG.md:4", "task-id")])

    def test_a_release_note_names_no_private_path_count_or_paperclip(self):
        found = self.check_release_notes("- Logs in /home/someone/x.\n- Stored under ~/.config/thing.\n"
                                         "- Output in /tmp/run/out.\n- The suite ran 380 tests.\n- Tracked on the paperclip board.\n")
        self.assertEqual(found, [("CHANGELOG.md:1", "home-path"), ("CHANGELOG.md:2", "dot-path"),
                                 ("CHANGELOG.md:3", "tmp-path"), ("CHANGELOG.md:4", "test-count"),
                                 ("CHANGELOG.md:5", "paperclip")])

    def test_a_released_entry_may_name_the_rig_and_the_emulator(self):
        self.assertEqual(self.check_release_notes("- A hidden test rig (`dev/rig`) with a small Android emulator.\n"), [])

    def test_the_release_notes_pass(self):
        self.assertEqual(ptc.check_public_files(RULES), [])

    def test_every_pattern_it_names_exists(self):
        self.assertTrue(set(RULES["public_files"]["pattern_ids"]) <= {p["id"] for p in RULES["environment"]["patterns"]})


class Twin(unittest.TestCase):
    """The twin repository holds the same checker and the same rules, apart from
    each one's own lines (LOCAL_RULES)."""

    def setUp(self):
        with open(SCRIPT) as handle:
            self.checker = handle.read()
        with open(ptc.RULES_FILE) as handle:
            self.rules_text = handle.read()

    def twin_rules(self, change=None):
        rules = json.loads(self.rules_text)
        rules["repository"], rules["twin"] = rules["twin"], rules["repository"]
        for pat in rules["environment"]["patterns"]:
            if pat["id"] == "paperclip":
                pat["regex"] = "\\bother\\b"
            if "unless_match" in pat:
                pat["unless_match"] = "other\\.plugin"
            if "allowed_when_changed" in pat:
                pat["allowed_when_changed"] = [re.sub(r"^tests/", "test/", f) for f in pat["allowed_when_changed"]]
        if change:
            change(rules)
        return json.dumps(rules, indent=1)

    def test_each_repository_s_own_lines_are_no_drift(self):
        self.assertEqual(ptc.drift(self.checker, self.rules_text, self.checker, self.twin_rules()), [])

    def test_a_changed_rule_or_checker_is_drift(self):
        def narrower(rules):
            rules["open_item"]["markers"][0]["regex"] += "x"
        self.assertEqual(ptc.drift(self.checker, self.rules_text, self.checker, self.twin_rules(narrower)),
                         ["dev/public-text-rules.json"])
        self.assertEqual(ptc.drift(self.checker, self.rules_text, self.checker + "\n", self.rules_text),
                         ["dev/public-text-check"])

    def fake_api(self, heads):
        """heads: ref -> (checker, rules) of the twin; every ref but develop is an open pull request."""
        twin = RULES["twin"]

        def api(path, token):
            if path.startswith("/repos/%s/pulls?" % twin):
                return [{"html_url": "https://github.com/%s/pull/%d" % (twin, i), "head": {"sha": ref}}
                        for i, ref in enumerate(r for r in heads if r != "develop")]
            name, ref = re.match(r"/repos/[^/]+/[^/]+/contents/(.+)\?ref=(.+)$", path).groups()
            text = heads[ref][ptc.TWIN_FILES.index(name)]
            return {"content": base64.b64encode(text.encode()).decode()}
        return api

    def check(self, heads):
        with mock.patch.object(ptc, "api", self.fake_api(heads)):
            return ptc.check_twin(RULES, "token", SCRIPT)

    def test_it_matches_the_twin_s_develop(self):
        where, differ = self.check({"develop": (self.checker, self.twin_rules())})
        self.assertEqual((where, differ), ("%s develop" % RULES["twin"], []))

    def test_a_change_made_in_both_lands_one_pull_request_at_a_time(self):
        where, differ = self.check({"develop": (self.checker + "# old\n", self.twin_rules()),
                                    "aaa": (self.checker + "# other\n", self.twin_rules()),
                                    "bbb": (self.checker, self.twin_rules())})
        self.assertEqual((where, differ), ("https://github.com/%s/pull/1" % RULES["twin"], []))

    def test_a_change_in_one_repository_alone_fails(self):
        where, differ = self.check({"develop": (self.checker + "# old\n", self.twin_rules())})
        self.assertEqual((where, differ), (None, ["dev/public-text-check"]))


class Rules(unittest.TestCase):
    def test_every_pattern_compiles_and_has_an_id(self):
        patterns = (RULES["environment"]["patterns"] + RULES["open_item"]["markers"] +
                    RULES["unlinked_reference"]["patterns"] + RULES["standing"]["patterns"])
        for pat in patterns:
            re.compile(pat["regex"])
            for key in ("unless_near", "unless_before", "unless_match"):
                if key in pat:
                    re.compile(pat[key])
        re.compile(RULES["open_item"]["reference"])


class Workflow(unittest.TestCase):
    PATH = os.path.join(ROOT, ".github", "workflows", "public-text.yml")

    def setUp(self):
        with open(self.PATH) as handle:
            self.text = handle.read()

    def test_it_runs_on_the_events_that_carry_public_text(self):
        for event in ("pull_request:", "pull_request_review:", "pull_request_review_comment:", "issue_comment:"):
            self.assertIn("\n  " + event, self.text)

    def test_a_push_to_develop_reads_what_lands_and_a_comment_after_the_merge(self):
        self.assertRegex(self.text, r"(?m)^  push:\n    branches: \[develop\]$")
        self.assertIn("github.event.issue.pull_request", self.text)
        self.assertIn("cancel-in-progress: ${{ github.event_name != 'push' }}", self.text)

    def test_it_reads_with_a_read_only_token(self):
        self.assertIn("pull-requests: read", self.text)
        self.assertNotRegex(self.text, r"(?m)^\s+(contents|pull-requests|issues|statuses|checks): write")

    def test_no_text_from_the_event_reaches_a_shell(self):
        for expression in re.findall(r"\$\{\{(.*?)\}\}", self.text):
            self.assertNotRegex(expression, r"\.(body|title|head\.ref|head\.label|message|name)\b", expression)


if __name__ == "__main__":
    unittest.main()
