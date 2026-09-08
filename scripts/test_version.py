import unittest
from version import next_version

class VersionTests(unittest.TestCase):
    def test_semantic_increments(self):
        self.assertEqual(next_version('1.2.3', 'major'), '2.0.0')
        self.assertEqual(next_version('1.2.3', 'minor'), '1.3.0')
        self.assertEqual(next_version('1.2.3', 'patch'), '1.2.4')

    def test_build_only_keeps_product_version(self):
        self.assertEqual(next_version('0.1.0', 'build'), '0.1.0')

if __name__ == '__main__':
    unittest.main()
