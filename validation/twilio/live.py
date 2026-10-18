#!/usr/bin/env python3
"""Bounded, isolated live Twilio caller; run via the consumer Keychain launcher."""
import base64
import hashlib
import hmac
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
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "examples/order_desk/scripts"))
from twilio_route import RoutingError, RoutingLease, TwilioAPI


def available_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def get_json(url):
    with urllib.request.urlopen(url, timeout=2) as response:
        return json.load(response)


def wait_for(action, seconds=40):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            value = action()
            if value:
                return value
        except (OSError, ValueError):
            pass
        time.sleep(0.2)
    raise RoutingError("Local validation service readiness timed out")


def jwt(environment, application, identity):
    def encoded(value):
        return base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).rstrip(b"=")
    now = int(time.time())
    key = environment["TWILIO_API_KEY_SID"]
    header = {"typ": "JWT", "alg": "HS256", "cty": "twilio-fpa;v=1"}
    claims = {"jti": key + "-" + secrets.token_hex(12), "iss": key,
              "sub": environment["TWILIO_ACCOUNT_SID"], "iat": now, "exp": now + 900,
              "grants": {"identity": identity, "voice": {"outgoing": {"application_sid": application}}}}
    content = encoded(header) + b"." + encoded(claims)
    signature = hmac.new(environment["TWILIO_API_KEY_SECRET"].encode(), content, hashlib.sha256).digest()
    return (content + b"." + base64.urlsafe_b64encode(signature).rstrip(b"=")).decode()


def terminate(process):
    if process and process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=12)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def main():
    if os.environ.get("PARLORA_ACCEPTANCE_LIVE") != "1":
        raise RoutingError("Explicit PARLORA_ACCEPTANCE_LIVE=1 required")
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=False)
    suite = len(sys.argv) > 2 and sys.argv[2] in ("--suite", "--controls")
    controls = len(sys.argv) > 2 and sys.argv[2] == "--controls"
    environment = os.environ.copy()
    api = TwilioAPI(environment)
    api.check_idle()
    # Do not reuse or change an existing ngrok agent.
    with socket.socket() as check:
        if check.connect_ex(("127.0.0.1", 4040)) == 0:
            raise RoutingError("An ngrok agent already owns port 4040; it was left unchanged")
    phone_port, review_port = available_port(), available_port()
    identity = "parlora-probe-" + secrets.token_hex(8)
    nonce = secrets.token_urlsafe(24)
    tunnel = server = caller = lease = application = None
    cleanup = {}
    server_log = None
    try:
        tunnel = subprocess.Popen(["ngrok", "http", str(phone_port), "--inspect=false", "--log=stdout"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        public = wait_for(lambda: next((t["public_url"] for t in get_json("http://127.0.0.1:4040/api/tunnels")["tunnels"]
                                       if t["public_url"].startswith("https://")), None))
        environment.update(TWILIO_PUBLIC_URL=public, TWILIO_PORT=str(phone_port), TWILIO_REVIEW_PORT=str(review_port),
                           TWILIO_TEST_NONCE=nonce, ORDER_DESK_DATABASE=str(output / "demo.sqlite3"),
                           ERL_FLAGS="+sbwt none +sbwtdcpu none +sbwtdio none",
                           RUSTUP_TOOLCHAIN="1.92.0-aarch64-apple-darwin")
        server_log = (output / "server.log").open("w")
        server = subprocess.Popen(["mix", "run", str(ROOT / "validation/twilio/server.exs")],
                                  cwd="/Users/humberto/Projects/parlora_consumer", env=environment,
                                  stdout=server_log, stderr=subprocess.STDOUT, start_new_session=True)
        review = f"http://localhost:{review_port}"
        wait_for(lambda: get_json(review + "/health"))
        application = api.request("/Applications.json", {"FriendlyName": identity,
                                  "VoiceUrl": public + "/__test/dial", "VoiceMethod": "POST"})["sid"]
        lease = RoutingLease(api, public)
        lease.install()
        print("Temporary routing verified; controlled call starting.", flush=True)
        audio = output / "status124.wav"
        subprocess.run(["/usr/bin/say", "-v", "Samantha", "-r", "165", "--file-format=WAVE", "--data-format=LEI16@24000",
                        "-o", str(audio), "Check order one hundred twenty four."], check=True, timeout=20)
        config = {"token": jwt(environment, application, identity), "nonce": nonce, "review": review,
                  "audio": str(audio), "report": str(output / ("suite.json" if suite else "caller.json")), "output": str(output), "controls": controls}
        caller_log = (output / "caller.log").open("w")
        caller = subprocess.Popen(["node", str(ROOT / ("validation/twilio/suite.cjs" if suite else "validation/twilio/caller.cjs"))], stdin=subprocess.PIPE,
                                  stdout=caller_log, stderr=subprocess.DEVNULL, start_new_session=True)
        caller.communicate(json.dumps(config).encode(), timeout=840 if suite else 100)
        caller_log.close()
        report = json.loads(Path(config["report"]).read_text())
        expected = 1 if controls else 6
        passed = (len(report.get("cases", [])) == expected and all(case["status"] == "passed" for case in report["cases"])) if suite else report.get("passed", False)
        if caller.returncode != 0 or not passed:
            raise RoutingError("Live acceptance failed; evidence is preserved")
        print("Controlled caller finished; restoring routing and cleaning resources.", flush=True)
    finally:
        # Keep normal shutdown from interrupting restoration a second time.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        terminate(caller)
        try:
            # Only calls belonging to this unique SDK identity, and their child legs.
            parents = api.request("/Calls.json?" + urllib.parse.urlencode({"From": "client:" + identity, "PageSize": 20})).get("calls", [])
            calls = list(parents)
            for parent in parents:
                calls.extend(api.request("/Calls.json?" + urllib.parse.urlencode({"ParentCallSid": parent["sid"], "PageSize": 20})).get("calls", []))
            cleanup["calls"] = [{"direction": call["direction"], "status": call["status"], "duration": call.get("duration")} for call in calls]
            for call in calls:
                if call["status"] in ("queued", "ringing", "in-progress"):
                    api.request(f'/Calls/{call["sid"]}.json', {"Status": "completed"})
        except RoutingError:
            cleanup["calls"] = "cleanup_unverified"
        try:
            if lease:
                # Retry transport failures, never overwrite a concurrent external change.
                for attempt in range(3):
                    try:
                        cleanup["routing"] = lease.restore()
                        break
                    except RoutingError as error:
                        cleanup["routing"] = str(error)
                        if "externally" in str(error) or attempt == 2:
                            raise
                        time.sleep(1)
        finally:
            try:
                if application:
                    api.request(f"/Applications/{application}.json", method="DELETE")
                    cleanup["temporary_application"] = "deleted"
            finally:
                terminate(server)
                terminate(tunnel)
                if server_log:
                    server_log.close()
                (output / "cleanup.json").write_text(json.dumps(cleanup, indent=2) + "\n")
                print(json.dumps(cleanup), flush=True)



if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Live validation interrupted; inspect cleanup.json for restoration evidence", flush=True)
        sys.exit(130)
    except (RoutingError, subprocess.TimeoutExpired) as error:
        # Never serialize subprocess arguments/environments or credential-bearing responses.
        print(str(error) if isinstance(error, RoutingError) else "Bounded live test timed out", flush=True)
        sys.exit(1)
