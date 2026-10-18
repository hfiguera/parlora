"""Offline safety checks for temporary routing; never contacts Twilio."""
import unittest
from twilio_route import RoutingError, RoutingLease


class FakeAPI:
    def __init__(self):
        self.state = {"voice_url": "https://original.example/voice", "voice_method": "GET",
                      "voice_application_sid": "AP-existing", "trunk_sid": "",
                      "voice_fallback_url": "https://original.example/fallback",
                      "status_callback": "https://original.example/status"}
        self.writes = []
        self.uncertain = False
        self.active = False

    def check_idle(self):
        if self.active:
            raise RoutingError("Active call")

    def fetch(self):
        return self.state.copy()

    def update(self, fields):
        self.writes.append(fields.copy())
        self.state.update(fields)
        if self.uncertain:
            self.uncertain = False
            raise RoutingError("Response lost")


class RoutingTest(unittest.TestCase):
    def test_restore_exact_fields_without_modifying_shared_application(self):
        api = FakeAPI()
        before = api.fetch()
        lease = RoutingLease(api, "https://test.example")
        lease.install()
        self.assertEqual(api.state["voice_application_sid"], "")
        self.assertNotIn("trunk_sid", api.writes[0])
        lease.restore()
        self.assertEqual(api.state, before)

    def test_concurrent_routing_changes_are_not_overwritten(self):
        api = FakeAPI()
        lease = RoutingLease(api, "https://test.example")
        lease.install()
        api.state["voice_url"] = "https://someone-else.example/voice"
        with self.assertRaises(RoutingError):
            lease.restore()
        self.assertEqual(len(api.writes), 1)

    def test_uncertain_install_is_reconciled_before_restoration(self):
        api = FakeAPI()
        before = api.fetch()
        api.uncertain = True
        lease = RoutingLease(api, "https://test.example")
        with self.assertRaises(RoutingError):
            lease.install()
        lease.restore()
        self.assertEqual(api.state, before)

    def test_active_calls_prevent_mutation(self):
        api = FakeAPI()
        api.active = True
        lease = RoutingLease(api, "https://test.example")
        with self.assertRaises(RoutingError):
            lease.install()
        lease.restore()
        self.assertEqual(api.writes, [])


if __name__ == "__main__":
    unittest.main()
