#!/usr/bin/env python3
"""Copy a multi_llm_review run's pending directory into log/, before the
reaper can take it.

A run that is never collected is deleted once its collect deadline passes
(pending_state.rb dir_reapable?): the directory is reduced to marker.json +
reaped.json and the seats' replies are gone. A COLLECTED run is pinned
forever, so this script matters most between dispatch and collect.

Run it twice per round — right after dispatch, and right after collect.
It copies whatever exists at the moment it runs, so the second call picks up
the files the first call could not see.

    python3 scripts/mlr_snapshot.py <collect_token>

Writes to log/mlr_snapshots/<token>/ and appends one line per file to
manifest.tsv (when, name, bytes, sha256). Never writes into .kairos/.
Exit 1 if the pending directory is missing — a silent success there would be
the failure this script exists to prevent.
"""
import hashlib
import os
import shutil
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PENDING = os.path.join(ROOT, '.kairos', 'multi_llm_review', 'pending')
DEST = os.path.join(ROOT, 'log', 'mlr_snapshots')


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def main(token):
    src = os.path.join(PENDING, token)
    if not os.path.isdir(src):
        print(f"NO PENDING DIR: {src}", file=sys.stderr)
        print("  the run was never dispatched, or it has already been reaped.",
              file=sys.stderr)
        return 1

    dst = os.path.join(DEST, token)
    os.makedirs(dst, exist_ok=True)
    stamp = time.strftime('%Y-%m-%dT%H:%M:%S%z')
    manifest = os.path.join(dst, 'manifest.tsv')
    new_manifest = not os.path.exists(manifest)

    copied, skipped = [], []
    with open(manifest, 'a') as mf:
        if new_manifest:
            mf.write("when\tname\tbytes\tsha256\n")
        for name in sorted(os.listdir(src)):
            s = os.path.join(src, name)
            if not os.path.isfile(s) or os.path.getsize(s) == 0:
                skipped.append(name)
                continue
            d = os.path.join(dst, name)
            digest = sha256(s)
            # Same content already here — record nothing, copy nothing.
            if os.path.exists(d) and sha256(d) == digest:
                skipped.append(name)
                continue
            shutil.copy2(s, d)
            size = os.path.getsize(d)
            mf.write(f"{stamp}\t{name}\t{size}\t{digest}\n")
            copied.append((name, size, digest[:12]))

    print(f"snapshot {token} -> {os.path.relpath(dst, ROOT)}")
    for name, size, digest in copied:
        print(f"  copied  {name:26} {size:>9,} bytes  {digest}")
    if skipped:
        print(f"  skipped (empty or unchanged): {', '.join(skipped)}")
    if not copied:
        print("  nothing new to copy")

    # Exit non-zero when what was copied is a tombstone rather than a run.
    # Copying marker.json + reaped.json and reporting success is the silent
    # failure this script exists to prevent: the seats' replies are already
    # gone and no snapshot can bring them back. Same for a directory that
    # holds no reply file at all.
    if os.path.exists(os.path.join(src, 'reaped.json')):
        print("  ALREADY REAPED: the replies are gone; only the tombstone was "
              "copied.", file=sys.stderr)
        return 1
    if not os.path.exists(os.path.join(src, 'subprocess_results.json')):
        print("  NO REPLIES YET: subprocess_results.json is absent — run this "
              "again after the seats finish, and again after collect.",
              file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
