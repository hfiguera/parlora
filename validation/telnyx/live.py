#!/usr/bin/env python3
"""Bounded real Telnyx calls from the existing fixed-destination Twilio SDK harness."""
import importlib.util
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import sys
import time
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "examples/order_desk/scripts"))
from telnyx_route import TelnyxAPI, RoutingLease, RoutingError
from twilio_route import TwilioAPI, RoutingError as TwilioError

spec = importlib.util.spec_from_file_location("twilio_live_helpers", ROOT / "validation/twilio/live.py")
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)


def main():
    if os.environ.get("PARLORA_ACCEPTANCE_LIVE") != "1":
        raise RoutingError("Explicit PARLORA_ACCEPTANCE_LIVE=1 required")
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    output = Path(sys.argv[1]).resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    suite = len(sys.argv) > 2 and sys.argv[2] in ("--suite", "--controls")
    environment = os.environ.copy()
    telnyx, twilio = TelnyxAPI(environment), TwilioAPI(environment)
    telnyx.check_association()
    telnyx.check_idle()
    with socket.socket() as check:
        if check.connect_ex(("127.0.0.1", 4040)) == 0:
            raise RoutingError("An existing ngrok agent was left unchanged")
    phone_port, review_port = shared.available_port(), shared.available_port()
    identity = "parlora-telnyx-" + secrets.token_hex(8)
    nonce = secrets.token_urlsafe(24)
    tunnel = server = caller = lease = application = None
    cleanup = {}
    review = None
    server_log = None
    try:
        tunnel = subprocess.Popen(["ngrok", "http", str(phone_port), "--inspect=false", "--log=stdout"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        public = shared.wait_for(lambda: next((t["public_url"] for t in shared.get_json("http://127.0.0.1:4040/api/tunnels")["tunnels"]
                                            if t["public_url"].startswith("https://")), None))
        environment.update(TELNYX_PUBLIC_URL=public, TELNYX_PORT=str(phone_port), TELNYX_REVIEW_PORT=str(review_port),
                           TWILIO_TEST_NONCE=nonce, ORDER_DESK_DATABASE=str(output / "demo.sqlite3"),
                           ERL_FLAGS="+sbwt none +sbwtdcpu none +sbwtdio none",
                           RUSTUP_TOOLCHAIN="1.92.0-aarch64-apple-darwin")
        server_log = (output / "server.log").open("w")
        server = subprocess.Popen(["mix", "run", str(ROOT / "validation/telnyx/server.exs")],
            cwd="/Users/humberto/Projects/parlora_consumer", env=environment,
            stdout=server_log, stderr=subprocess.STDOUT, start_new_session=True)
        review = f"http://localhost:{review_port}"
        shared.wait_for(lambda: shared.get_json(review + "/health"), seconds=120)
        application = twilio.request("/Applications.json", {"FriendlyName": identity,
            "VoiceUrl": public + "/__test/dial", "VoiceMethod": "POST"})["sid"]
        lease = RoutingLease(telnyx, public)
        lease.install()
        print("Temporary Telnyx routing verified; fixed-destination caller starting.", flush=True)
        audio = output / "status124.wav"
        subprocess.run(["/usr/bin/say", "-v", "Samantha", "-r", "165", "--file-format=WAVE", "--data-format=LEI16@24000",
                        "-o", str(audio), "Check order one hundred twenty four."], check=True, timeout=20)
        config = {"channel": "telnyx", "token": shared.jwt(environment, application, identity), "nonce": nonce, "review": review,
                  "audio": str(audio), "report": str(output / ("suite.json" if suite else "caller.json")),
                  "output": str(output), "controls": len(sys.argv) > 2 and sys.argv[2] == "--controls"}
        with (output / "caller.log").open("w") as caller_log:
            script = "suite.cjs" if suite else "caller.cjs"
            caller = subprocess.Popen(["node", str(ROOT / "validation/twilio" / script)], stdin=subprocess.PIPE,
                stdout=caller_log, stderr=subprocess.DEVNULL, start_new_session=True)
            caller.communicate(json.dumps(config).encode(), timeout=840 if suite else 100)
        report = json.loads(Path(config["report"]).read_text())
        expected = 1 if config["controls"] else 6
        passed = (len(report.get("cases", [])) == expected and all(c["status"] == "passed" for c in report["cases"])) if suite else report.get("passed", False)
        if caller.returncode != 0 or not passed:
            raise RoutingError("Live Telnyx acceptance failed; evidence is preserved")
        print("Controlled Telnyx call finished; restoring routing.", flush=True)
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        shared.terminate(caller)
        try:
            parents = twilio.request("/Calls.json?" + urllib.parse.urlencode({"From": "client:" + identity, "PageSize": 20})).get("calls", [])
            calls = list(parents)
            for parent in parents:
                calls.extend(twilio.request("/Calls.json?" + urllib.parse.urlencode({"ParentCallSid": parent["sid"], "PageSize": 20})).get("calls", []))
            for call in calls:
                if call["status"] in ("queued", "ringing", "in-progress"):
                    twilio.request(f'/Calls/{call["sid"]}.json', {"Status": "completed"})
            cleanup["caller_legs"] = [{"status": c["status"], "duration": c.get("duration")} for c in calls]
        except TwilioError:
            cleanup["caller_cleanup"] = "unverified"
        try:
            if review:
                for endpoint, file in [("state", "final-sessions.json"), ("calls", "final-calls.json")]:
                    try:
                        (output / file).write_text(json.dumps(shared.get_json(review + "/__acceptance/" + endpoint), indent=2) + "\n")
                    except (OSError, ValueError):
                        cleanup[endpoint + "_evidence"] = "unavailable"
            if lease:
                for attempt in range(37):
                    try:
                        cleanup["routing"] = lease.restore()
                        break
                    except RoutingError as error:
                        cleanup["routing"] = str(error)
                        if "active calls" not in str(error) or attempt == 36:
                            raise
                        time.sleep(5)
        finally:
            try:
                if application:
                    twilio.request(f"/Applications/{application}.json", method="DELETE")
                    cleanup["temporary_caller_application"] = "deleted"
            finally:
                shared.terminate(server)
                shared.terminate(tunnel)
                if server_log:
                    server_log.close()
                (output / "cleanup.json").write_text(json.dumps(cleanup, indent=2) + "\n")
                print(json.dumps(cleanup), flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Interrupted; inspect cleanup.json for restoration evidence", flush=True)
        sys.exit(130)
    except (RoutingError, TwilioError, subprocess.TimeoutExpired) as error:
        print(str(error) if isinstance(error, (RoutingError, TwilioError)) else "Bounded live test timed out", flush=True)
        sys.exit(1)
