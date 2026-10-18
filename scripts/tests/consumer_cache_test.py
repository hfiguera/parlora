import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / 'support' / 'consumer_cache.sh'


class ConsumerCacheTest(unittest.TestCase):
    def run_helper(self, consumer, cache, operation, **overrides):
        env = {**os.environ, 'PARLORA_CONSUMER_CACHE': str(cache),
               'PARLORA_CONSUMER_MODE': 'full', **overrides}
        return subprocess.run(
            ['sh', '-eu', '-c', '. "$1"; parlora_consumer=$2; ' + operation,
             'consumer-cache-test', str(HELPER), str(consumer)],
            env=env, text=True, capture_output=True)

    def write(self, root, path, contents):
        file = root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(contents)
        return file

    def test_round_trip_reuses_dependencies_without_restoring_old_application_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            consumer, cache, fresh = (root / name for name in ['consumer', 'cache', 'fresh'])
            self.write(consumer, 'deps/example/lib/example.ex', 'dependency source')
            self.write(consumer, 'deps/example/target/release/old.so', 'native build')
            self.write(consumer, 'vendor/parlora/lib/parlora.ex', 'old library source')
            self.write(consumer, 'data/order_desk.sqlite3', 'private application data')
            for mode in ['dev', 'test', 'prod']:
                self.write(consumer, f'_build/{mode}/lib/example/ebin/example.beam', mode)
                self.write(consumer, f'_build/{mode}/rel/old_release', 'old release')
                for app in ['parlora', 'order_desk', 'optional_backend_consumer']:
                    self.write(consumer, f'_build/{mode}/lib/{app}/ebin/old.beam', 'old code')
            saved = self.run_helper(consumer, cache, 'parlora_save_consumer_cache')
            self.assertEqual(saved.returncode, 0, saved.stderr)
            self.assertFalse((cache / 'vendor').exists())
            self.assertFalse((cache / 'data').exists())
            self.assertFalse((cache / 'deps/example/target').exists())
            for mode in ['dev', 'test', 'prod']:
                self.assertFalse((cache / f'_build/{mode}/rel').exists())
                for app in ['parlora', 'order_desk', 'optional_backend_consumer']:
                    self.assertFalse((cache / f'_build/{mode}/lib/{app}').exists())
                    # Even a cache with old app output must not overwrite fresh code.
                    self.write(cache, f'_build/{mode}/lib/{app}/ebin/old.beam', 'stale')
            package = self.write(fresh, 'vendor/parlora/lib/parlora.ex', 'current source')
            restored = self.run_helper(fresh, cache, 'parlora_restore_consumer_cache')
            self.assertEqual(restored.returncode, 0, restored.stderr)
            self.assertEqual(package.read_text(), 'current source')
            self.assertEqual((fresh / 'deps/example/lib/example.ex').read_text(), 'dependency source')
            for mode in ['dev', 'test', 'prod']:
                self.assertEqual((fresh / f'_build/{mode}/lib/example/ebin/example.beam').read_text(), mode)
                for app in ['parlora', 'order_desk', 'optional_backend_consumer']:
                    self.assertFalse((fresh / f'_build/{mode}/lib/{app}').exists())

    def test_saving_updated_dependencies_removes_obsolete_cached_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            consumer, cache = root / 'consumer', root / 'cache'
            self.write(consumer, 'deps/example/new.ex', 'new')
            self.write(cache, 'deps/example/removed.ex', 'old')
            self.write(consumer, '_build/test/lib/example/ebin/new.beam', 'new')
            self.write(cache, '_build/test/lib/example/ebin/removed.beam', 'old')
            result = self.run_helper(consumer, cache, 'parlora_save_consumer_cache')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((cache / 'deps/example/removed.ex').exists())
            self.assertFalse((cache / '_build/test/lib/example/ebin/removed.beam').exists())

    def test_invalid_configuration_fails_before_touching_the_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for overrides in [{'PARLORA_CONSUMER_MODE': 'unknown'},
                              {'PARLORA_CONSUMER_CACHE': 'relative/path'}]:
                result = self.run_helper(root / 'consumer', root / 'cache',
                                         'parlora_restore_consumer_cache', **overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((root / 'cache').exists())


if __name__ == '__main__':
    unittest.main()
