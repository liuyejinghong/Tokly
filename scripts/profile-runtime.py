#!/usr/bin/env python3
"""Read CPU time, RSS and physical footprint for processes inside one app bundle."""
import argparse
import ctypes as C
import json
import platform
import plistlib
import statistics
import time
from pathlib import Path

FIELDS = ['user_time', 'system_time', 'pkg_idle_wkups', 'interrupt_wkups', 'pageins',
          'wired_size', 'resident_size', 'phys_footprint', 'proc_start_abstime',
          'proc_exit_abstime', 'child_user_time', 'child_system_time',
          'child_pkg_idle_wkups', 'child_interrupt_wkups', 'child_pageins',
          'child_elapsed_abstime', 'diskio_bytesread', 'diskio_byteswritten']
class Usage(C.Structure):
    _fields_ = [('uuid', C.c_uint8 * 16)] + [(key, C.c_uint64) for key in FIELDS]

class Timebase(C.Structure):
    _fields_ = [('numer', C.c_uint32), ('denom', C.c_uint32)]

TIMEBASE = Timebase()
SYSTEM = C.CDLL('/usr/lib/libSystem.B.dylib')
if SYSTEM.mach_timebase_info(C.byref(TIMEBASE)) != 0 or not TIMEBASE.denom:
    raise RuntimeError('Cannot read Mach timebase')
SECONDS_PER_TICK = TIMEBASE.numer / TIMEBASE.denom / 1e9

LIB = C.CDLL('/usr/lib/libproc.dylib', use_errno=True)
LIB.proc_pid_rusage.argtypes = [C.c_int, C.c_int, C.c_void_p]
LIB.proc_pidpath.argtypes = [C.c_int, C.c_void_p, C.c_uint32]
LIB.proc_listallpids.argtypes = [C.c_void_p, C.c_int]

def discover(app):
    capacity = max(LIB.proc_listallpids(None, 0) + 128, 1024)
    pids = (C.c_int * capacity)()
    count = LIB.proc_listallpids(pids, C.sizeof(pids))
    found = {}
    for pid in pids[:max(0, count)]:
        buffer = C.create_string_buffer(4096)
        if LIB.proc_pidpath(pid, buffer, len(buffer)) <= 0:
            continue
        path = buffer.value.decode('utf-8', errors='replace')
        if path.startswith(str(app) + '/'):
            found[pid] = Path(path).name
    return found

def sample(pid, name, elapsed):
    u = Usage()
    if LIB.proc_pid_rusage(pid, 2, C.byref(u)) != 0:
        return None
    return {'t': elapsed, 'pid': pid, 'name': name, 'start': u.proc_start_abstime,
            'cpuSeconds': (u.user_time + u.system_time) * SECONDS_PER_TICK,
            'childCpuSeconds': (u.child_user_time + u.child_system_time) * SECONDS_PER_TICK,
            'rssMiB': u.resident_size / 1048576, 'footprintMiB': u.phys_footprint / 1048576,
            'idleWakeups': u.pkg_idle_wkups, 'interruptWakeups': u.interrupt_wkups}

def summarize(rows):
    groups = {}
    for row in rows:
        groups.setdefault((row['pid'], row['start']), []).append(row)
    summaries = []
    for series in groups.values():
        first, last = series[0], series[-1]
        intervals = [(b['cpuSeconds'] - a['cpuSeconds']) / (b['t'] - a['t']) * 100
                     for a, b in zip(series, series[1:]) if b['t'] > a['t']]
        duration = last['t'] - first['t']
        delta = last['cpuSeconds'] - first['cpuSeconds']
        summaries.append({'name': first['name'], 'pid': first['pid'], 'samples': len(series),
                          'observedSeconds': duration, 'cpuSeconds': delta,
                          'averageCpuPercentOneCore': delta / duration * 100 if duration else None,
                          'peakSampleCpuPercentOneCore': max(intervals) if intervals else None,
                          'rssMiBMin': min(x['rssMiB'] for x in series),
                          'rssMiBMax': max(x['rssMiB'] for x in series),
                          'footprintMiBMedian': statistics.median(x['footprintMiB'] for x in series),
                          'footprintMiBMax': max(x['footprintMiB'] for x in series),
                          'childCpuSeconds': last['childCpuSeconds'] - first['childCpuSeconds']})
    return summaries

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--phase', required=True)
    p.add_argument('--seconds', type=float, default=60)
    p.add_argument('--interval', type=float, default=0.25)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if args.seconds <= 0 or args.interval < 0.05:
        p.error('positive duration and interval >= 0.05 required')
    app = args.app.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    result = {'phase': args.phase, 'recordedAt': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
              'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'),
              'configuration': info.get('ToklyBuildConfiguration'), 'gitCommit': info.get('ToklyGitCommit'),
              'platform': platform.platform(), 'intervalSeconds': args.interval,
              'method': 'macOS proc_pid_rusage RUSAGE_INFO_V2, Mach ticks converted using mach_timebase_info; 100% CPU = one logical core',
              'machTimebase': {'numer': TIMEBASE.numer, 'denom': TIMEBASE.denom},
              'limitations': 'Sampled peaks; very short-lived processes or their final CPU interval may be missed. Shared WidgetKit host costs are not attributed.'}
    start = time.monotonic(); rows = []; known = {}; next_discovery = 0
    while True:
        elapsed = time.monotonic() - start
        if elapsed >= next_discovery:
            known = discover(app); next_discovery = elapsed + 1
        for pid, name in known.items():
            row = sample(pid, name, elapsed)
            if row:
                rows.append(row)
        if elapsed >= args.seconds:
            break
        time.sleep(min(args.interval, args.seconds - elapsed))
    result['elapsedSeconds'] = time.monotonic() - start
    result['summary'] = summarize(rows); result['samples'] = rows
    if not rows:
        p.error('No readable target process samples; ensure the app runs and process inspection is permitted')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'samples'}, indent=2))

if __name__ == '__main__':
    main()
