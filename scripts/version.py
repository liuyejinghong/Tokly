#!/usr/bin/env python3
"""Check or increment the application version without building or publishing."""
import argparse
import json
import re
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / 'Config/Version.xcconfig'

def read():
    text = CONFIG.read_text()
    version = re.search(r'^MARKETING_VERSION = (\d+\.\d+\.\d+)$', text, re.M)
    build = re.search(r'^CURRENT_PROJECT_VERSION = ([1-9]\d*)$', text, re.M)
    if not version or not build:
        raise ValueError('Version.xcconfig must contain x.y.z and a positive build number')
    return version[1], int(build[1])

def next_version(version, part):
    values = list(map(int, version.split('.')))
    if part != 'build':
        index = ['major', 'minor', 'patch'].index(part)
        values[index] += 1
        for i in range(index + 1, 3):
            values[i] = 0
    return '.'.join(map(str, values))

def check(version):
    for path in [ROOT / 'Collector/Cargo.toml', ROOT / 'Collector/Cargo.lock']:
        data = tomllib.loads(path.read_text())
        package = data['package']
        if isinstance(package, list):
            package = next(p for p in package if p['name'] == 'tokens-collector')
        if package['version'] != version:
            raise ValueError(f'{path.relative_to(ROOT)} is out of sync')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['check', 'bump'], nargs='?', default='check')
    parser.add_argument('part', choices=['major', 'minor', 'patch', 'build'], nargs='?')
    args = parser.parse_args()
    version, build = read()
    check(version)
    if args.command == 'bump':
        if args.part is None:
            parser.error('bump needs major, minor, patch or build')
        new = next_version(version, args.part)
        manifest = ROOT / 'Collector/Cargo.toml'
        lock = ROOT / 'Collector/Cargo.lock'
        manifest_text = manifest.read_text().replace(f'version = "{version}"', f'version = "{new}"', 1)
        lock_text, count = re.subn(r'(name = "tokens-collector"\nversion = ")[^"]+("\n)',
                                  lambda m: m[1] + new + m[2], lock.read_text())
        if count != 1:
            raise ValueError('Expected exactly one collector lock entry')
        manifest.write_text(manifest_text)
        lock.write_text(lock_text)
        CONFIG.write_text(f'MARKETING_VERSION = {new}\nCURRENT_PROJECT_VERSION = {build + 1}\n')
        version, build = new, build + 1
        check(version)
    print(json.dumps({'version': version, 'build': build}))

if __name__ == '__main__':
    main()
