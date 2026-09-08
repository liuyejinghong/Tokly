import importlib.util
import os
from pathlib import Path
import time
import unittest

spec = importlib.util.spec_from_file_location('profile_runtime', Path(__file__).with_name('profile-runtime.py'))
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)

class ProfileTests(unittest.TestCase):
    def test_cpu_units_match_process_clock(self):
        first = profile.sample(os.getpid(), 'self', 0)
        start = time.process_time()
        while time.process_time() - start < 0.1:
            sum(range(1000))
        expected = time.process_time() - start
        last = profile.sample(os.getpid(), 'self', 1)
        self.assertIsNotNone(first)
        self.assertIsNotNone(last)
        self.assertAlmostEqual(last['cpuSeconds'] - first['cpuSeconds'], expected, delta=0.02)

if __name__ == '__main__':
    unittest.main()
