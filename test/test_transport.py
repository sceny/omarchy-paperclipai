"""The API clients' transport rules, in process.

    python3 -m unittest test/test_transport.py

What is pinned here: the token goes only to a loopback listener this user owns
(or https), a redirect is never followed, and a body is read with a cap. The
listener's owner comes from an injectable lookup, so a squatter owned by
another user can be simulated without a second account.
"""

import contextlib
import http.server
import importlib.machinery
import importlib.util
import io
import json
import os
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "bin", "omarchy-paperclip-status")
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_loader(
    "paperclip_status", importlib.machinery.SourceFileLoader("paperclip_status", SCRIPT))
status = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(status)

TOKEN = "board-token-for-tests"
ME = os.getuid()
OTHER = ME + 1


class Server:
    """A loopback server that records every request's headers."""

    def __init__(self, handler):
        self.requests = []
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                outer.requests.append(dict(self.headers))
                handler(self)

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        self.base = "http://127.0.0.1:%d" % self.port
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def owned_by(*uids):
    return lambda _address, _port: list(uids)


class TokenVerdict(unittest.TestCase):
    def test_loopback_listener_that_is_ours(self):
        for base in ("http://127.0.0.1:3100", "http://127.0.0.2:3100", "http://[::1]:3100",
                     "http://localhost:3100"):
            self.assertEqual(status.token_verdict(base, owned_by(ME)), "send", base)

    def test_listener_that_is_not_ours(self):
        self.assertEqual(status.token_verdict("http://127.0.0.1:3100", owned_by(OTHER)), "untrusted")

    def test_any_foreign_socket_on_the_port_spoils_it(self):
        self.assertEqual(status.token_verdict("http://127.0.0.1:3100", owned_by(ME, OTHER)), "untrusted")

    def test_nobody_listening_sends_nothing(self):
        self.assertEqual(status.token_verdict("http://127.0.0.1:3100", owned_by()), "no-listener")

    def test_an_unreadable_table_fails_closed(self):
        self.assertEqual(status.token_verdict("http://127.0.0.1:3100", lambda *_: None), "untrusted")

    def test_plain_http_to_another_host_never(self):
        for base in ("http://192.0.2.1:3100", "http://paperclip.example", "http://10.0.0.5:3100",
                     "ftp://127.0.0.1:3100", "127.0.0.1:3100"):
            self.assertEqual(status.token_verdict(base, owned_by(ME)), "insecure", base)

    def test_https_goes_anywhere(self):
        self.assertEqual(status.token_verdict("https://paperclip.example", owned_by(OTHER)), "send")


class ProcTable(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        head = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
        v4 = (head
              + "   0: 0100007F:0C1C 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 11 1 0 100 0\n"
              + "   1: 0100007F:0C1D 00000000:0000 0A 00000000:00000000 00:00000000 00000000  0           0 12 1 0 100 0\n"
              + "   2: 0100007F:0C1C 0100007F:9999 01 00000000:00000000 00:00000000 00000000  7           0 13 1 0 100 0\n"
              + "   3: 00000000:0C1E 00000000:0000 0A 00000000:00000000 00:00000000 00000000  0           0 14 1 0 100 0\n")
        v6 = (head
              + "   0: 00000000000000000000000001000000:0C1F 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  0           0 15 1 0 100 0\n"
              + "   1: 00000000000000000000000000000000:0C20 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  5           0 16 1 0 100 0\n"
              + "   2: 0000000000000000FFFF00000100007F:0C21 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  6           0 17 1 0 100 0\n")
        self.files = (os.path.join(self.dir, "tcp"), os.path.join(self.dir, "tcp6"))
        for path, text in zip(self.files, (v4, v6)):
            with open(path, "w") as handle:
                handle.write(text)

    def owners(self, ip, port):
        import ipaddress
        return status._proc_listener_uids(ipaddress.ip_address(ip), port, self.files)

    def test_exact_address_and_only_listen_state(self):
        self.assertEqual(self.owners("127.0.0.1", 0x0C1C), [1000])
        self.assertEqual(self.owners("127.0.0.1", 0x0C1D), [0])

    def test_wildcard_listener_receives_loopback(self):
        self.assertEqual(self.owners("127.0.0.1", 0x0C1E), [0])
        self.assertEqual(self.owners("::1", 0x0C1E), [])
        self.assertEqual(self.owners("::1", 0x0C20), [5])
        self.assertEqual(self.owners("127.0.0.1", 0x0C20), [5])

    def test_ipv6_loopback_and_mapped_addresses(self):
        self.assertEqual(self.owners("::1", 0x0C1F), [0])
        self.assertEqual(self.owners("127.0.0.1", 0x0C1F), [])
        self.assertEqual(self.owners("127.0.0.1", 0x0C21), [6])

    def test_other_port_and_unreadable_table(self):
        self.assertEqual(self.owners("127.0.0.1", 9), [])
        import ipaddress
        self.assertIsNone(status._proc_listener_uids(
            ipaddress.ip_address("127.0.0.1"), 1, (os.path.join(self.dir, "missing"),)))

    def test_this_machine_reports_a_socket_we_own(self):
        import ipaddress
        import socket
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        sock.listen(1)
        try:
            owners = status._proc_listener_uids(
                ipaddress.ip_address("127.0.0.1"), sock.getsockname()[1])
            self.assertEqual(owners, [ME])
        finally:
            sock.close()


class Fetch(unittest.TestCase):
    def test_a_redirect_is_an_error_and_nothing_follows_it(self):
        for code in (301, 302, 303, 307, 308):
            target = Server(lambda h: (h.send_response(200), h.end_headers(), h.wfile.write(b"{}")))
            squatter = Server(lambda h, t=target: (
                h.send_response(code), h.send_header("Location", t.base + "/api/health"),
                h.end_headers()))
            try:
                reply = status.fetch(squatter.base, TOKEN, "GET", "/api/health",
                                     uid_lookup=owned_by(ME))
                self.assertEqual(reply.error, "redirect refused", code)
                self.assertEqual(reply.code, "redirect")
                self.assertEqual(target.requests, [], "the redirect target was reached")
            finally:
                squatter.close()
                target.close()

    def test_no_token_to_a_listener_that_is_not_ours(self):
        server = Server(lambda h: (h.send_response(200), h.end_headers(), h.wfile.write(b"{}")))
        try:
            reply = status.fetch(server.base, TOKEN, "GET", "/api/health", uid_lookup=owned_by(OTHER))
            self.assertEqual(reply.code, "untrusted")
            self.assertEqual(server.requests, [], "a request reached the foreign listener")
        finally:
            server.close()

    def test_the_token_reaches_our_own_listener(self):
        server = Server(lambda h: (h.send_response(200), h.end_headers(), h.wfile.write(b"{}")))
        try:
            reply = status.fetch(server.base, TOKEN, "GET", "/api/health")
            self.assertEqual(reply.status, 200)
            self.assertEqual(server.requests[0].get("Authorization"), "Bearer " + TOKEN)
        finally:
            server.close()

    def test_an_environment_proxy_never_sees_the_token(self):
        proxy = Server(lambda h: (h.send_response(200), h.end_headers(), h.wfile.write(b"{}")))
        server = Server(lambda h: (h.send_response(200), h.end_headers(), h.wfile.write(b"{}")))
        saved = {k: os.environ.get(k) for k in ("http_proxy", "HTTP_PROXY", "no_proxy", "NO_PROXY")}
        os.environ["http_proxy"] = os.environ["HTTP_PROXY"] = proxy.base
        os.environ.pop("no_proxy", None)
        os.environ.pop("NO_PROXY", None)
        try:
            status.fetch(server.base, TOKEN, "GET", "/api/health")
            self.assertEqual(proxy.requests, [])
            self.assertEqual(len(server.requests), 1)
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
            proxy.close()
            server.close()

    def test_an_oversize_body_is_an_error_and_is_not_read_to_the_end(self):
        sent = []

        def flood(h):
            h.send_response(200)
            h.end_headers()
            chunk = b"x" * 65536
            try:
                while len(sent) * len(chunk) < 64 * 1024 * 1024:
                    h.wfile.write(chunk)
                    sent.append(1)
            except OSError:
                pass

        server = Server(flood)
        try:
            reply = status.fetch(server.base, "", "GET", "/api/health")
            self.assertEqual((reply.error, reply.code), ("answer too large", "too-large"))
            self.assertLess(len(sent) * 65536, 16 * 1024 * 1024, "the reader kept going")
        finally:
            server.close()

    def test_an_oversize_error_body_is_capped_too(self):
        def flood(h):
            h.send_response(500)
            h.end_headers()
            try:
                for _ in range(200):
                    h.wfile.write(b"x" * 65536)
            except OSError:
                pass

        server = Server(flood)
        try:
            reply = status.fetch(server.base, "", "GET", "/api/health")
            self.assertEqual(reply.code, "too-large")
            self.assertEqual(reply.status, 500)
        finally:
            server.close()


class Probe(unittest.TestCase):
    def run_probe(self, base, uid_lookup):
        original = status._proc_listener_uids
        saved = os.environ.get("PAPERCLIP_OMARCHY_TOKEN")
        os.environ["PAPERCLIP_OMARCHY_TOKEN"] = TOKEN
        status._proc_listener_uids = uid_lookup
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out):
                status.main(["--api-base", base, "--compact", "--instance", "no-such-instance-xyz"])
        finally:
            status._proc_listener_uids = original
            if saved is None:
                os.environ.pop("PAPERCLIP_OMARCHY_TOKEN", None)
            else:
                os.environ["PAPERCLIP_OMARCHY_TOKEN"] = saved
        return json.loads(out.getvalue())

    def test_a_foreign_listener_is_a_state_and_gets_nothing(self):
        server = Server(lambda h: (h.send_response(200), h.end_headers(), h.wfile.write(b"{}")))
        try:
            report = self.run_probe(server.base, owned_by(OTHER))
            self.assertEqual(report["state"], "untrusted-listener")
            self.assertFalse(report["reachable"])
            self.assertEqual(server.requests, [])
            self.assertTrue(any("not sent" in line for line in report["problems"]), report["problems"])
        finally:
            server.close()

    def test_plain_http_to_another_host_is_a_state_and_connects_nowhere(self):
        report = self.run_probe("http://192.0.2.1:3100", owned_by(ME))
        self.assertEqual(report["state"], "untrusted-listener")
        self.assertTrue(any("plain http" in line for line in report["problems"]), report["problems"])

    def test_nobody_listening_is_still_stopped(self):
        report = self.run_probe("http://127.0.0.1:9", owned_by())
        self.assertFalse(report["reachable"])
        self.assertIn(report["state"], ("stopped", "not-installed"))


if __name__ == "__main__":
    unittest.main()
