#!/usr/bin/env python3
"""Git merge driver for CHANGELOG.md that keeps fork notes from conflicting.

The fork records its changes under "## [Unreleased]" at the top of the file,
which is exactly where upstream adds each new release section, so a plain
merge or rebase conflicts every time. This driver pulls the Unreleased section
out of all three versions, merges the rest of the file normally, merges the
Unreleased entries separately (keeping both sides when they overlap), and puts
the Unreleased section back above the newest release.

Git runs it as:  changelog_merge.py %O %A %B
(base, current, other). The result is written to %A. Exit 0 means a clean
merge; non-zero leaves conflict markers for a person (or --claude-fix).

sync_fork_deploy.sh installs it into .git/ and registers it in the local git
config, so it needs no committed .gitattributes.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

HEADING = '## [Unreleased]'


def split_unreleased(text):
    """Return (text without the Unreleased section, that section's body)."""
    lines = text.splitlines(keepends=True)
    start = next((i for i, line in enumerate(lines) if line.strip() == HEADING), None)
    if start is None:
        return text, ''
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith('## [')), len(lines))
    return ''.join(lines[:start] + lines[end:]), ''.join(lines[start + 1:end])


def merge_file(current, base, other, union=False):
    """Three-way merge of strings via git merge-file. Returns (text, conflicts)."""
    with tempfile.TemporaryDirectory() as tmp:
        paths = []
        for name, content in (('current', current), ('base', base), ('other', other)):
            path = Path(tmp) / name
            path.write_text(content)
            paths.append(str(path))
        cmd = ['git', 'merge-file', '-p', '-L', 'current', '-L', 'base', '-L', 'other']
        if union:
            cmd.append('--union')
        result = subprocess.run(cmd + paths, capture_output=True, text=True)
    if result.returncode < 0 or result.returncode > 127:
        raise RuntimeError(result.stderr)
    return result.stdout, result.returncode


def main():
    base_path, current_path, other_path = sys.argv[1:4]
    base, current, other = (Path(p).read_text() for p in (base_path, current_path, other_path))

    base_rest, base_notes = split_unreleased(base)
    current_rest, current_notes = split_unreleased(current)
    other_rest, other_notes = split_unreleased(other)

    merged, conflicts = merge_file(current_rest, base_rest, other_rest)
    notes, note_conflicts = merge_file(current_notes, base_notes, other_notes)
    if note_conflicts:
        notes, _ = merge_file(current_notes, base_notes, other_notes, union=True)

    if notes.strip():
        if not notes.endswith('\n\n'):
            notes = notes.rstrip('\n') + '\n\n'
        lines = merged.splitlines(keepends=True)
        at = next((i for i, line in enumerate(lines) if line.startswith('## [')), len(lines))
        if notes.startswith('\n'):
            section = [HEADING + '\n', notes]
        else:
            section = [HEADING + '\n\n', notes]
        merged = ''.join(lines[:at] + section + lines[at:])

    Path(current_path).write_text(merged)
    return 1 if conflicts else 0


if __name__ == '__main__':
    sys.exit(main())
