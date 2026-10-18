#!/usr/bin/env python3
"""Inspect or temporarily route the development Telnyx application; secrets stay in memory."""
import argparse
import base64
import json
import os
import signal
import threading
import urllib.error
import urllib.parse
import urllib.request


class RoutingError(RuntimeError):
    """A sanitized operational error."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, _request, _fp, _code, _message, _headers, _url):
        raise RoutingError("Telnyx API redirect rejected")


FIELDS = ("application_name", "webhook_event_url", "webhook_event_failover_url", "webhook_api_version")


def same_routing(left, right):
    """The API may represent an unset optional failover URL as null or empty."""
    def normalized(fields):
        return dict(fields, webhook_event_failover_url=fields.get("webhook_event_failover_url") or None)
    return normalized(left) == normalized(right)


class TelnyxAPI:
    def __init__(self, environment):
        self.key = environment["TELNYX_API_KEY"]
        self.number = environment["TELNYX_PHONE_NUMBER"]
        self.connection = environment["TELNYX_VOICE_API_CONNECTION_ID"]
        self.path = "/call_control_applications/" + urllib.parse.quote(self.connection, safe="")

    def request(self, path, fields=None):
        request = urllib.request.Request(
            "https://api.telnyx.com/v2" + path,
            data=None if fields is None else json.dumps(fields).encode(),
            method="GET" if fields is None else "PATCH",
            headers={"Authorization": "Bearer " + self.key, "Content-Type": "application/json"},
        )
        try:
            with urllib.request.build_opener(NoRedirect()).open(request, timeout=15) as response:
                raw = response.read(1_048_577)
                if len(raw) > 1_048_576:
                    raise RoutingError("Telnyx API response exceeded the bound")
                return json.loads(raw)
        except urllib.error.HTTPError as error:
            raise RoutingError(f"Telnyx request failed with HTTP {error.code}") from None
        except (urllib.error.URLError, TimeoutError, ValueError):
            raise RoutingError("Telnyx request failed; remote outcome may be uncertain") from None

    def check_association(self):
        query = urllib.parse.urlencode({"filter[connection_id]": self.connection, "page[size]": 100})
        result = self.request("/phone_numbers?" + query)
        numbers = result["data"]
        if result.get("meta", {}).get("total_results") != 1 or len(numbers) != 1:
            raise RoutingError("Development connection is shared or association cannot be established")
        number = numbers[0]
        if number.get("phone_number") != self.number or str(number.get("connection_id")) != self.connection:
            raise RoutingError("Development number does not match the configured connection")

    def check_idle(self):
        path = "/connections/" + urllib.parse.quote(self.connection, safe="") + "/active_calls"
        if self.request(path)["data"]:
            raise RoutingError("Development connection has active calls; routing was not changed")

    def fetch(self):
        application = self.request(self.path)["data"]
        if not application.get("active") or str(application.get("id")) != self.connection:
            raise RoutingError("Development application is inactive or mismatched")
        return {field: application.get(field) for field in FIELDS}

    def update(self, fields):
        self.request(self.path, fields)


class RoutingLease:
    def __init__(self, api, public_url):
        url = urllib.parse.urlsplit(public_url)
        if url.scheme != "https" or not url.hostname or url.username or url.password or url.path or url.query or url.fragment or url.port not in (None, 443):
            raise RoutingError("TELNYX_PUBLIC_URL must be an HTTPS origin without a path")
        self.api = api
        self.target = public_url + "/telnyx/events"
        self.previous = None
        self.desired = None

    def install(self):
        self.api.check_association()
        self.api.check_idle()
        self.previous = self.api.fetch()
        self.desired = dict(self.previous, webhook_event_url=self.target,
                            webhook_event_failover_url=None, webhook_api_version="2")
        # Retain the exact desired state before PATCH: a lost response can hide success.
        self.api.update(self.desired)
        if not same_routing(self.api.fetch(), self.desired):
            raise RoutingError("Temporary routing could not be verified")

    def restore(self):
        if self.previous is None or self.desired is None:
            return "not_modified"
        current = self.api.fetch()
        if same_routing(current, self.previous):
            return "restored_and_verified"
        if not same_routing(current, self.desired):
            raise RoutingError("Routing changed externally; restoration refused to overwrite it")
        self.api.check_association()
        self.api.check_idle()
        self.api.update(self.previous)
        if not same_routing(self.api.fetch(), self.previous):
            raise RoutingError("Original routing restoration could not be verified")
        return "restored_and_verified"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preflight", action="store_true")
    parser.add_argument("--seconds", type=int, default=300)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 900:
        parser.error("--seconds must be between 1 and 900")
    api = TelnyxAPI(os.environ)
    if args.preflight:
        api.check_association()
        api.check_idle()
        current = api.fetch()
        if len(base64.b64decode(os.environ["TELNYX_WEBHOOK_PUBLIC_KEY"], validate=True)) != 32:
            raise RoutingError("Invalid webhook verification key")
        print(json.dumps({"preflight": "passed", "associated_numbers": 1, "active_calls": 0,
                          "webhook_configured": bool(current["webhook_event_url"]),
                          "webhook_api_version": current["webhook_api_version"]}))
        return
    stop = threading.Event()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda _signum, _frame: stop.set())
    lease = RoutingLease(api, os.environ["TELNYX_PUBLIC_URL"])
    try:
        lease.install()
        print(json.dumps({"routing": "temporary", "maximum_seconds": args.seconds}), flush=True)
        stop.wait(args.seconds)
    finally:
        # Keep the server running for active calls; retry restoration for one
        # bounded call-duration grace period, never hang up a caller to restore.
        for attempt in range(37):
            try:
                result = lease.restore()
                print(json.dumps({"routing": result}), flush=True)
                break
            except RoutingError as error:
                if "active calls" not in str(error) or attempt == 36:
                    raise
                threading.Event().wait(5)


if __name__ == "__main__":
    try:
        main()
    except (RoutingError, KeyError, ValueError) as error:
        message = str(error) if isinstance(error, RoutingError) else "Invalid or missing Telnyx runtime configuration"
        print(message, flush=True)
        raise SystemExit(1) from None
