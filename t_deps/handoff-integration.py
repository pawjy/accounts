"""Destructive ONLY to a disposable Accounts fixture DB; never point at user data.

Run in an isolated test container with MariaDB CLI and Accounts HTTP server:
  HANDOFF_TEST_SOCKET=/tmp/handoff/mysql.sock python3 t_deps/handoff-integration.py
The fixture client 'iphone' maps web-login -> web, terms v2, Google, fixed HTTPS.
Uses real HTTP handlers and InnoDB; seeded identity substitutes for the provider.
"""

import base64, concurrent.futures, hashlib, json, os, secrets, subprocess, time, unittest
import shutil
import urllib.error, urllib.parse, urllib.request

BASE = os.environ.get("HANDOFF_TEST_ORIGIN", "http://127.0.0.1:8082")
BEARER = os.environ.get("HANDOFF_TEST_BEARER", "fixture")
if "HANDOFF_TEST_SOCKET" in os.environ:
    db_options = ["--socket=" + os.environ["HANDOFF_TEST_SOCKET"], "-uroot", "accounts"]
else:
    db = json.loads(os.environ["HANDOFF_TEST_DB"])
    if db["dbname"] != "accounts_test":
        raise ValueError("Expected the disposable Accounts test database")
    db_options = [
        "--protocol=TCP",
        "--host=" + str(db["host"]),
        "--port=" + str(db["port"]),
        "--user=" + db["user"],
        db["dbname"],
    ]
    os.environ["MYSQL_PWD"] = db["password"]


def sql(statement):
    client = shutil.which("mariadb") or shutil.which("mysql")
    return (
        subprocess.check_output(
            [client, "--no-defaults", "-N", "-B", *db_options], input=statement.encode()
        )
        .decode()
        .strip()
    )


def quoted(v):
    return "X'" + str(v).encode().hex() + "'"


def request(path, params, authorized=True):
    r = urllib.request.Request(
        BASE + path,
        data=urllib.parse.urlencode(params).encode(),
        headers={
            "Authorization": "Bearer " + BEARER if authorized else "Bearer invalid"
        },
    )
    try:
        res = urllib.request.urlopen(r, timeout=30)
    except urllib.error.HTTPError as e:
        res = e
    b = res.read()
    return (
        res.status,
        json.loads(b) if res.headers.get_content_type() == "application/json" else {},
        res.headers,
    )


class Handoff(unittest.TestCase):
    def setUp(self):
        self.aid = secrets.randbelow(10**12) + 10**12
        self.sk = secrets.token_hex(50)
        self.verifier = secrets.token_urlsafe(32)
        self.when = int(time.time()) - 120
        self.d = {
            "handoff_login": 1,
            "google": {"transient": "discard"},
            "session_id": str(self.aid),
            "account_id": str(self.aid),
            "login_time": self.when,
            "handoff_request": {
                "client": "iphone",
                "state": secrets.token_urlsafe(32),
                "challenge": base64.urlsafe_b64encode(
                    hashlib.sha256(self.verifier.encode()).digest()
                )
                .decode()
                .rstrip("="),
                "redirect_uri": "https://login.example.test/account/app/return",
                "expires": time.time() + 600,
                "authentication": {
                    "method": "oauth",
                    "provider": "google",
                    "login_time": self.when,
                },
            },
        }
        sql(f"INSERT INTO account VALUES ({self.aid},0,1,1,2,'Fixture');")
        sql(
            f"INSERT INTO session VALUES ({quoted(self.sk)},'web-login',0,{time.time() + 600},{quoted(json.dumps(self.d))});"
        )

    def update(self):
        sql(
            f"UPDATE session SET data={quoted(json.dumps(self.d))} WHERE sk={quoted(self.sk)}"
        )

    def issue(self, **params):
        return request(
            "/session/handoff/issue",
            {
                "sk_context": "web-login",
                "sk": self.sk,
                "client_info": json.dumps({"platform": "ios"}),
                **params,
            },
        )

    def code(self):
        status, body, headers = self.issue()
        self.assertEqual(status, 200, body)
        self.assertEqual(headers["Cache-Control"], "no-store")
        return body["code"]

    def redeem(self, code, **kw):
        return request(
            "/session/handoff/redeem",
            {
                "sk_context": "web-login",
                "client_id": "iphone",
                "code": code,
                "code_verifier": self.verifier,
                **kw,
            },
        )

    def test_success_independent_regular_session(self):
        code = self.code()
        status, result, h = self.redeem(code)
        self.assertEqual(status, 200, result)
        self.assertNotEqual(result["sk"], self.sk)
        self.assertEqual(h["Cache-Control"], "no-store")
        rows = sql("SELECT data FROM session WHERE sk=" + quoted(result["sk"]))
        d = json.loads(rows)
        self.assertEqual(d["account_id"], str(self.aid))
        self.assertEqual(d["login_time"], self.when)
        self.assertNotEqual(d["session_id"], self.d["session_id"])
        self.assertNotIn("handoff_request", d)
        self.assertEqual(
            request("/info", {"sk_context": "web", "sk": result["sk"]})[1][
                "account_id"
            ],
            str(self.aid),
        )
        self.assertEqual(
            request("/info", {"sk_context": "web-login", "sk": result["sk"]})[1].get(
                "account_id"
            ),
            None,
        )
        request(
            "/session/delete", {"use_sk": 1, "sk_context": "web", "sk": result["sk"]}
        )
        self.assertEqual(
            request("/info", {"sk_context": "web-login", "sk": self.sk})[0], 400
        )

    def test_concurrent_issuance(self):
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda _: self.issue(), range(2)))
        self.assertEqual(sorted(r[0] for r in results), [200, 400])
        self.assertEqual(
            sql(
                "SELECT COUNT(*) FROM session WHERE sk_context='app-handoff-v1' AND JSON_VALUE(data,'$.handoff.source_session_id')="
                + str(self.aid)
            ),
            "1",
        )
        self.assertEqual(
            self.redeem(next(r[1]["code"] for r in results if r[0] == 200))[0], 200
        )

    def test_rollback_and_retry(self):
        code = self.code()

        def counts():
            return sql(
                "SELECT COUNT(*) FROM session WHERE sk_context='web' AND JSON_VALUE(data,'$.account_id')="
                + str(self.aid)
            ), sql(
                "SELECT COUNT(*) FROM session_recent_log WHERE sk_context='web' AND account_id="
                + str(self.aid)
            )

        sql(f"""DELIMITER //
CREATE TRIGGER audit_failure BEFORE INSERT ON session_recent_log FOR EACH ROW
BEGIN
  IF NEW.account_id = {self.aid} THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fixture';
  END IF;
END//
DELIMITER ;
""")
        try:
            self.assertEqual(self.redeem(code)[0], 400)
            self.assertEqual(counts(), ("0", "0"))
        finally:
            sql("DROP TRIGGER audit_failure")
        self.assertEqual(self.redeem(code)[0], 200)
        self.assertEqual(counts(), ("1", "1"))
        self.assertEqual(self.redeem(code)[0], 400)

    def test_session_history(self):
        code = self.code()
        self.assertNotIn(
            "google",
            json.loads(sql("SELECT data FROM session WHERE sk=" + quoted(self.sk))),
        )
        status, body, _ = self.redeem(code)
        self.assertEqual(status, 200)

        def history():
            return json.loads(
                sql(
                    "SELECT data FROM session_recent_log WHERE sk=" + quoted(body["sk"])
                )
            )

        audit = history()
        self.assertEqual(
            audit,
            {
                "ua": "",
                "ipaddr": "",
                "login_method": "oauth",
                "service_name": "google",
                "source_operation": "session/handoff",
                "source_session_id": str(self.aid),
                "client_info": {"platform": "ios"},
            },
        )
        request("/session", {"sk_context": "web", "sk": body["sk"]})
        self.assertEqual(history(), audit)

    def test_invalid_client_info(self):
        for value in ("", "null", "[]", "1", "{", '{"label":"' + "x" * 1024 + '"}'):
            self.assertEqual(self.issue(client_info=value)[0], 400)
        self.assertEqual(
            request(
                "/session/handoff/issue", {"sk_context": "web-login", "sk": self.sk}
            )[0],
            400,
        )
        self.code()

    def test_login_session_scope_and_ttl(self):
        _, login, _ = request("/session", {"sk_context": "web-login"})
        self.assertLessEqual(login["sk_expires"], time.time() + 600)
        for route in (
            "/info",
            "/token",
            "/session/get",
            "/session/delete",
            "/link",
            "/create",
            "/login/email/request",
        ):
            self.assertEqual(
                request(route, {"sk_context": "web-login", "sk": self.sk})[0], 400
            )
        self.assertIsNone(
            request("/info", {"sk_context": "web", "sk": self.sk})[1].get("account_id")
        )
        self.assertEqual(
            request(
                "/agree",
                {
                    "version": 2,
                    "sk_context": "web-login",
                    "sk": self.sk,
                    "downgrade": 1,
                },
            )[0],
            400,
        )
        self.code()
        self.assertEqual(
            request("/agree", {"version": 2, "sk_context": "web-login", "sk": self.sk})[
                0
            ],
            400,
        )

    def test_replay(self):
        code = self.code()
        self.assertEqual(self.redeem(code)[0], 200)
        self.assertEqual(self.redeem(code)[0], 400)

    def test_concurrent_redemption(self):
        code = self.code()
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            statuses = list(pool.map(lambda _: self.redeem(code)[0], range(2)))
        self.assertEqual(sorted(statuses), [200, 400])

    def test_wrong_verifier_does_not_consume(self):
        code = self.code()
        self.assertEqual(self.redeem(code, code_verifier="x" * 43)[0], 400)
        self.assertEqual(self.redeem(code)[0], 200)

    def test_wrong_environment(self):
        code = self.code()
        self.assertEqual(self.redeem(code, sk_context="production")[0], 400)
        self.assertEqual(self.redeem(code, client_id="other")[0], 400)
        self.assertEqual(self.redeem(code)[0], 200)

    def test_issue_once(self):
        self.code()
        self.assertEqual(self.issue()[0], 400)

    def test_expired_code(self):
        code = self.code()
        key = "h1" + hashlib.sha256(code.encode()).hexdigest() + "0" * 34
        sql("UPDATE session SET expires=0 WHERE sk=" + quoted(key))
        self.assertEqual(self.redeem(code)[0], 400)

    def test_source_logout(self):
        code = self.code()
        sql("DELETE FROM session WHERE sk=" + quoted(self.sk))
        self.assertEqual(self.redeem(code)[0], 400)

    def test_source_expiry(self):
        code = self.code()
        sql("UPDATE session SET expires=0 WHERE sk=" + quoted(self.sk))
        self.assertEqual(self.redeem(code)[0], 400)

    def test_source_identity_changed(self):
        code = self.code()
        self.d["account_id"] = "1"
        self.update()
        self.assertEqual(self.redeem(code)[0], 400)

    def test_source_reauthenticated(self):
        code = self.code()
        self.d["login_time"] += 1
        self.update()
        self.assertEqual(self.redeem(code)[0], 400)

    def test_account_disabled_after_issue(self):
        code = self.code()
        sql(f"UPDATE account SET admin_status=0 WHERE account_id={self.aid}")
        self.assertEqual(self.redeem(code)[0], 400)

    def test_terms_withdrawn_after_issue(self):
        code = self.code()
        sql(f"UPDATE account SET terms_version=1 WHERE account_id={self.aid}")
        self.assertEqual(self.redeem(code)[0], 400)

    def test_no_terms(self):
        sql(f"UPDATE account SET terms_version=1 WHERE account_id={self.aid}")
        self.assertEqual(self.issue()[0], 400)

    def test_not_authenticated(self):
        del self.d["handoff_request"]["authentication"]
        self.update()
        self.assertEqual(self.issue()[0], 400)

    def test_expired_request(self):
        self.d["handoff_request"]["expires"] = 0
        self.update()
        self.assertEqual(self.issue()[0], 400)

    def test_return_uri_changed(self):
        self.d["handoff_request"]["redirect_uri"] = "https://evil.example/return"
        self.update()
        self.assertEqual(self.issue()[0], 400)

    def test_unregistered_provider(self):
        self.d["handoff_request"]["authentication"]["provider"] = "other"
        self.update()
        self.assertEqual(self.issue()[0], 400)

    def test_handoff_record_not_a_session(self):
        code = self.code()
        key = "h1" + hashlib.sha256(code.encode()).hexdigest() + "0" * 34
        self.assertEqual(
            request("/session/get", {"sk_context": "app-handoff-v1", "sk": key})[1].get(
                "account_id"
            ),
            None,
        )
        self.assertEqual(
            request("/info", {"sk_context": "app-handoff-v1", "sk": key})[1].get(
                "account_id"
            ),
            None,
        )

    def test_api_key_required(self):
        self.assertEqual(
            request(
                "/session/handoff/issue",
                {"sk_context": "web-login", "sk": self.sk},
                False,
            )[0],
            401,
        )

    def test_ordinary_session_unchanged(self):
        status, s, _ = request("/session", {"sk_context": "normal"})
        self.assertEqual(status, 200)
        self.assertTrue(s["set_sk"])
        self.assertEqual(len(s["sk"]), 100)
        status, r, _ = request("/session", {"sk_context": "normal", "sk": s["sk"]})
        self.assertEqual(status, 200)
        self.assertEqual(r["sk"], s["sk"])
        self.assertFalse(r.get("set_sk"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
