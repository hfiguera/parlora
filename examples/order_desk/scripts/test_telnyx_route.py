"""Offline routing tests: python3 -m unittest discover -s scripts -p 'test_telnyx_route.py'."""
import unittest
from telnyx_route import RoutingError, RoutingLease


class API:
    def __init__(self):
        self.fields = {"application_name": "development", "webhook_event_url": "https://original.test/events",
                       "webhook_event_failover_url": None, "webhook_api_version": "2"}
        self.original = dict(self.fields)
        self.active = False
        self.shared = False
        self.uncertain = False
        self.updates = 0

    def check_association(self):
        if self.shared:
            raise RoutingError("Shared application")

    def check_idle(self):
        if self.active:
            raise RoutingError("Connection has active calls")

    def fetch(self):
        return dict(self.fields)

    def update(self, fields):
        self.fields.update(fields)
        self.updates += 1
        if self.uncertain:
            self.uncertain = False
            raise RoutingError("Response lost")


class RoutingTest(unittest.TestCase):
    def test_empty_failover_response_is_equivalent_to_null(self):
        api = API()
        lease = RoutingLease(api, "https://tunnel.test")
        lease.install()
        api.fields["webhook_event_failover_url"] = ""
        self.assertEqual(lease.restore(), "restored_and_verified")
        self.assertEqual(api.fields, api.original)

    def test_restore_and_idempotent_repeat(self):
        api = API()
        lease = RoutingLease(api, "https://tunnel.test")
        lease.install()
        self.assertEqual(api.fields["webhook_event_url"], "https://tunnel.test/telnyx/events")
        self.assertEqual(lease.restore(), "restored_and_verified")
        self.assertEqual(lease.restore(), "restored_and_verified")
        self.assertEqual(api.fields, api.original)
        self.assertEqual(api.updates, 2)

    def test_uncertain_patch_is_reconciled(self):
        api = API()
        api.uncertain = True
        lease = RoutingLease(api, "https://tunnel.test")
        with self.assertRaises(RoutingError):
            lease.install()
        self.assertEqual(lease.restore(), "restored_and_verified")
        self.assertEqual(api.fields, api.original)

    def test_external_changes_are_preserved(self):
        api = API()
        lease = RoutingLease(api, "https://tunnel.test")
        lease.install()
        api.fields["webhook_event_url"] = "https://someone-else.test"
        with self.assertRaises(RoutingError):
            lease.restore()
        self.assertEqual(api.updates, 1)

    def test_active_or_shared_calls_block_install_and_restore(self):
        for field in ["active", "shared"]:
            api = API()
            lease = RoutingLease(api, "https://tunnel.test")
            setattr(api, field, True)
            with self.assertRaises(RoutingError):
                lease.install()
            self.assertEqual(api.updates, 0)
            setattr(api, field, False)
            lease.install()
            setattr(api, field, True)
            with self.assertRaises(RoutingError):
                lease.restore()
            self.assertEqual(api.updates, 1)


if __name__ == "__main__":
    unittest.main()
