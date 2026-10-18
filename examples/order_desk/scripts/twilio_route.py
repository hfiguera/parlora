#!/usr/bin/env python3
"""Temporarily route the development number; keep credentials and prior URLs in memory."""
import argparse
import base64
import json
import os
import re
import signal
import threading
import urllib.error
import urllib.parse
import urllib.request


class RoutingError(RuntimeError):
    """A sanitized operational error."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, _request, _fp, _code, _message, _headers, _url):
        raise RoutingError("Twilio API redirect rejected")


FIELDS = {
    "voice_url": "VoiceUrl", "voice_method": "VoiceMethod",
    "voice_application_sid": "VoiceApplicationSid", "trunk_sid": "TrunkSid",
    "voice_fallback_url": "VoiceFallbackUrl", "status_callback": "StatusCallback",
}


class TwilioAPI:
    def __init__(self, environment):
        self.account = environment["TWILIO_ACCOUNT_SID"]
        self.number_sid = environment["TWILIO_PHONE_NUMBER_SID"]
        self.number = environment["TWILIO_PHONE_NUMBER"]
        if not re.fullmatch(r"AC[0-9a-fA-F]{32}", self.account) or not re.fullmatch(r"PN[0-9a-fA-F]{32}", self.number_sid):
            raise RoutingError("Invalid account or phone resource identity")
        user = environment.get("TWILIO_API_KEY_SID") or self.account
        secret = environment.get("TWILIO_API_KEY_SECRET") or environment["TWILIO_AUTH_TOKEN"]
        self.authorization = "Basic " + base64.b64encode((user + ":" + secret).encode()).decode()
        self.root = f"https://api.twilio.com/2010-04-01/Accounts/{self.account}"
        self.phone_path = f"/IncomingPhoneNumbers/{self.number_sid}.json"

    def request(self, path, fields=None, method=None):
        data = None if fields is None else urllib.parse.urlencode(fields).encode()
        request = urllib.request.Request(self.root + path, data=data, method=method, headers={
            "Authorization": self.authorization,
            "Content-Type": "application/x-www-form-urlencoded",
        })
        try:
            with urllib.request.build_opener(NoRedirect()).open(request, timeout=15) as response:
                return {} if response.status == 204 else json.load(response)
        except urllib.error.HTTPError as error:
            raise RoutingError(f"Twilio request failed with HTTP {error.code}") from None
        except (urllib.error.URLError, TimeoutError, ValueError):
            raise RoutingError("Twilio request failed; remote outcome may be uncertain") from None

    def fetch(self):
        result = self.request(self.phone_path)
        if result.get("phone_number") != self.number or result.get("account_sid") != self.account:
            raise RoutingError("Development phone resource does not match configured identity")
        if not result.get("capabilities", {}).get("voice"):
            raise RoutingError("Development phone resource is not voice capable")
        return {name: result.get(name) or "" for name in FIELDS}

    def update(self, fields):
        self.request(self.phone_path, {FIELDS[name]: value for name, value in fields.items()})

    def check_idle(self):
        for status in ("queued", "ringing", "in-progress"):
            for direction in ("To", "From"):
                query = urllib.parse.urlencode({"Status": status, direction: self.number, "PageSize": 1})
                if self.request("/Calls.json?" + query).get("calls"):
                    raise RoutingError("Development number has an active call; routing was not changed")


class RoutingLease:
    def __init__(self, api, public_url):
        url = urllib.parse.urlsplit(public_url)
        if url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment or url.path or url.port not in (None, 443):
            raise RoutingError("TWILIO_PUBLIC_URL must be an HTTPS origin without a path")
        self.api = api
        self.target = public_url + "/twilio/voice"
        self.previous = None
        self.changed = {}

    def install(self):
        self.api.check_idle()
        self.previous = self.api.fetch()
        desired = {"voice_url": self.target, "voice_method": "POST",
                   "voice_application_sid": "", "trunk_sid": "",
                   "voice_fallback_url": "", "status_callback": ""}
        self.changed = {key: value for key, value in desired.items() if self.previous[key] != value}
        # Retain intent before POST: a failed response can hide a successful update.
        self.api.update(self.changed)
        current = self.api.fetch()
        if any(current[key] != value for key, value in self.changed.items()):
            raise RoutingError("Temporary routing could not be verified")

    def restore(self):
        if self.previous is None or not self.changed:
            return "not_modified"
        current = self.api.fetch()
        # Already restored (or POST never applied): no additional mutation needed.
        if all(current[key] == self.previous[key] for key in self.changed):
            return "restored_and_verified"
        if any(current[key] != value for key, value in self.changed.items()):
            raise RoutingError("Routing changed externally; automatic restoration refused to overwrite it")
        self.api.update({key: self.previous[key] for key in self.changed})
        verified = self.api.fetch()
        if any(verified[key] != self.previous[key] for key in self.changed):
            raise RoutingError("Original routing restoration could not be verified")
        return "restored_and_verified"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=300)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 900:
        parser.error("--seconds must be between 1 and 900")
    stop = threading.Event()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda _signum, _frame: stop.set())
    lease = RoutingLease(TwilioAPI(os.environ), os.environ["TWILIO_PUBLIC_URL"])
    try:
        lease.install()
        print(json.dumps({"routing": "temporary", "fields_changed": sorted(lease.changed), "maximum_seconds": args.seconds}), flush=True)
        stop.wait(args.seconds)
    finally:
        result = lease.restore()
        print(json.dumps({"routing": result}), flush=True)


if __name__ == "__main__":
    try:
        main()
    except RoutingError as error:
        # RoutingError messages are constants/status codes, never API response bodies.
        print(str(error), flush=True)
        raise SystemExit(1) from None
    except KeyError:
        print("Required Twilio runtime configuration is missing", flush=True)
        raise SystemExit(1) from None
