#!/usr/bin/python3
"""OmaControl live process sampler: top processes by *current* CPU.

`ps -o pcpu` is CPU time divided by process lifetime, so a process that just
spiked ranks low and one that was busy hours ago ranks high. This samples
like top instead: per-process CPU-time and I/O deltas between collector
ticks, from one pass over /proc.

usage: proc-sample.py STATE_FILE IO_RATE_OUT [TOP_N]

stdout       TOP_N lines "pid pcpu pmem comm", highest live CPU first.
             pcpu is % of one core (the ps unit; collect.sh divides by the
             core count), pmem is % of MemTotal.
IO_RATE_OUT  "pid kbs" lines (storage read+write KB/s) for the listed pids.
STATE_FILE   counters from this tick, read back on the next one.

With no usable baseline (first run, reboot, or a gap over MAX_GAP seconds)
it takes two snapshots SETTLE seconds apart instead, so values are always
live, never lifetime averages.

Test hooks: OMC_PROC_ROOT (default /proc), OMC_CLOCK (fixed clock, seconds).
"""
import os
import sys
import time

PROC = os.environ.get("OMC_PROC_ROOT", "/proc")
HZ = os.sysconf("SC_CLK_TCK")
PAGE = os.sysconf("SC_PAGE_SIZE")
MAX_GAP = 30.0
SETTLE = 0.2


def clock():
    fixed = os.environ.get("OMC_CLOCK")
    return float(fixed) if fixed else time.monotonic()


def mem_total_bytes():
    try:
        with open(os.path.join(PROC, "meminfo")) as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) * 1024
    except (OSError, ValueError, IndexError):
        pass
    return 0


def read_io(pid):
    """Storage bytes read+written, or None when not readable (other users)."""
    try:
        with open(os.path.join(PROC, pid, "io")) as f:
            r = w = 0
            for line in f:
                if line.startswith("read_bytes:"):
                    r = int(line.split()[1])
                elif line.startswith("write_bytes:"):
                    w = int(line.split()[1])
            return r + w
    except (OSError, ValueError, IndexError):
        return None


def snapshot():
    """{(pid, starttime): (comm, cpu_ticks, rss_pages, io_bytes|None)}"""
    snap = {}
    try:
        names = os.listdir(PROC)
    except OSError:
        return snap
    for pid in names:
        if not pid.isdigit():
            continue
        try:
            with open(os.path.join(PROC, pid, "stat")) as f:
                data = f.read()
        except OSError:
            continue  # exited between listdir and open
        lp, rp = data.find("("), data.rfind(")")
        if lp < 0 or rp < lp:
            continue
        comm = data[lp + 1:rp]
        rest = data[rp + 2:].split()
        try:
            # stat fields 14 utime, 15 stime, 22 starttime, 24 rss (1-based)
            ticks = int(rest[11]) + int(rest[12])
            start = rest[19]
            rss = int(rest[21])
        except (IndexError, ValueError):
            continue
        snap[(pid, start)] = (comm, ticks, rss, read_io(pid))
    return snap


def load_state(path):
    try:
        with open(path) as f:
            head = f.readline().split()
            if len(head) != 2 or head[0] != "t":
                return None, {}
            t = float(head[1])
            prev = {}
            for line in f:
                p = line.split()
                if len(p) != 4:
                    continue
                prev[(p[0], p[1])] = (int(p[2]), None if p[3] == "-" else int(p[3]))
            return t, prev
    except (OSError, ValueError):
        return None, {}


def save_state(path, t, snap):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w") as f:
            f.write("t %.3f\n" % t)
            for (pid, start), (_, ticks, _, io) in snap.items():
                f.write("%s %s %d %s\n" % (pid, start, ticks, "-" if io is None else io))
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def main():
    if len(sys.argv) < 3:
        print("usage: proc-sample.py STATE_FILE IO_RATE_OUT [TOP_N]", file=sys.stderr)
        return 2
    state_path, io_out = sys.argv[1], sys.argv[2]
    top_n = int(sys.argv[3]) if len(sys.argv) > 3 else 20

    prev_t, prev = load_state(state_path)
    now = clock()
    cur = snapshot()
    dt = now - prev_t if prev_t is not None else -1.0
    if not prev or dt <= 0 or dt > MAX_GAP:
        # No usable baseline: measure a short live window instead.
        prev = {k: (v[1], v[3]) for k, v in cur.items()}
        t0 = time.monotonic()
        time.sleep(SETTLE)
        cur = snapshot()
        dt = max(time.monotonic() - t0, 0.001)
        now = clock()
    save_state(state_path, now, cur)

    total = mem_total_bytes()
    rows = []
    for key, (comm, ticks, rss, io) in cur.items():
        p = prev.get(key)
        if p is None:
            # Not in the baseline, so it started during this interval (a
            # reused PID has a new starttime and lands here too): all of its
            # CPU time and I/O happened inside the interval, like top.
            p = (0, 0)
        cpu = max(ticks - p[0], 0) / HZ / dt * 100.0
        io_kbs = 0.0
        if io is not None and p[1] is not None:
            io_kbs = max(io - p[1], 0) / 1024.0 / dt
        mem = rss * PAGE * 100.0 / total if total else 0.0
        rows.append((cpu, rss, int(key[0]), mem, comm, io_kbs))
    rows.sort(key=lambda r: (r[0], r[1]), reverse=True)
    rows = rows[:top_n]

    with open(io_out, "w") as f:
        for cpu, rss, pid, mem, comm, io_kbs in rows:
            f.write("%d %.1f\n" % (pid, io_kbs))
    out = sys.stdout
    for cpu, rss, pid, mem, comm, io_kbs in rows:
        out.write("%d %.1f %.1f %s\n" % (pid, cpu, mem, comm.replace("\n", " ")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
