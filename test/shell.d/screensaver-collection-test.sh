#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3

python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
prepare = root / "bin/omarchy-screensaver-prepare"


def check(value, label):
  if not value:
    raise AssertionError(label)
  print("ok - " + label, flush=True)


with tempfile.TemporaryDirectory() as temporary:
  temp = Path(temporary)
  source = temp / "art collection"
  source.mkdir()
  (source / "01.txt").write_text("FIRST\n")
  (source / "02.txt").write_text("⣿⣿⣿\nSECOND\n")

  def run(path=source, success=True):
    output = Path(tempfile.mkdtemp(dir=temp))
    result = subprocess.run([prepare, str(path), str(output)], cwd=temp, capture_output=True, timeout=5)
    check((result.returncode == 0) == success, "source preparation " + ("succeeds" if success else "refuses unusable input"))
    return [p.read_text() for p in sorted(output.glob("*.txt"))]

  check(run() == ["FIRST\n", "⣿⣿⣿\nSECOND\n"], "collection preserves text in filename order")
  check(run(source / "02.txt") == ["⣿⣿⣿\nSECOND\n"], "single-file source preserves braille")
  selected_link = temp / "selected-link"
  selected_link.symlink_to(source, target_is_directory=True)
  check(run(selected_link) == run(), "an explicitly selected directory symlink works")

  (source / "escape.txt").symlink_to(source / "01.txt")
  (source / "loop.txt").symlink_to(source / "loop.txt")
  (source / "folder.txt").mkdir()
  (source / "folder.txt" / "nested.txt").write_text("NESTED")
  os.mkfifo(source / "pipe.txt")
  (source / ".hidden.txt").write_text("HIDDEN")
  (source / "image.png").write_text("IMAGE")
  (source / "binary.txt").write_bytes(b"\xff\x00")
  (source / "empty.txt").write_text(" \n\t")
  (source / "escape-sequence.txt").write_text("\x1b]52;c;SEVMTE8=\x07")
  (source / "c1.txt").write_text("\u009b31m")
  (source / "oversize.txt").write_text("X" * 65537)
  (source / "wide.txt").write_text("X" * 513)
  (source / "tall.txt").write_text("X\n" * 129)
  check(run() == ["FIRST\n", "⣿⣿⣿\nSECOND\n"], "links, special files, non-text files, controls and excessive artwork are skipped")
  run(source / "pipe.txt", success=False)

  marker = temp / "EXECUTED"
  hostile = source / "03-$(touch EXECUTED) `touch EXECUTED`\n--help.txt"
  hostile.write_text("LITERAL NAME\n")
  check(run()[-1] == "LITERAL NAME\n" and not marker.exists(), "shell syntax, newlines and options in filenames remain data")
  with tempfile.TemporaryDirectory(dir=temp) as snapshot:
    subprocess.run([prepare, str(source), snapshot], check=True)
    (source / "01.txt").write_text("CHANGED\n")
    check((Path(snapshot) / "000.txt").read_text() == "FIRST\n", "playback copy is unaffected by source replacement")
    check((Path(snapshot) / "000.txt").stat().st_mode & 0o777 == 0o600, "playback files are private")

  empty = temp / "empty"
  empty.mkdir()
  run(empty, success=False)
  run(temp / "missing", success=False)
  run("relative/path", success=False)

  many = temp / "many"
  many.mkdir()
  for index in range(129):
    (many / f"{index:03d}.txt").write_text(str(index))
  check(len(run(many)) == 128, "artwork count is bounded")
  for index in range(4096 - 129 + 1):
    (many / f"extra-{index}").touch()
  run(many, success=False)

  # Exercise the real runtime with a fake desktop and renderer. Nothing reaches
  # the running compositor, the user's branding, or their processes.
  home = temp / "home"
  branding = home / ".config/omarchy/branding"
  branding.mkdir(parents=True)
  (branding / "screensaver.txt").write_text("DEFAULT\n")
  config = branding.parent / "shell.json"
  stubs = temp / "bin"
  stubs.mkdir()
  log = temp / "frames"
  calls = temp / "calls"
  scratch = temp / "scratch"
  scratch.mkdir()

  def stub(name, content):
    file = stubs / name
    file.write_text("#!/bin/bash\n" + content)
    file.chmod(0o755)

  stub("hyprctl", '''if [[ $1 == activewindow ]]; then
  if (( $(wc -l < "$FRAME_LOG") >= 4 )); then
    printf '%s\\n' '{"class":"other"}'
  else
    printf '%s\\n' '{"class":"org.omarchy.screensaver"}'
  fi
fi
''')
  stub("ttfx", 'printf "%s\\n" "$2" >> "$CALL_LOG"\nhead -n 1 -- "$2" >> "$FRAME_LOG"\n')
  stub("pgrep", 'sleep 0.1\n(( $(wc -l < "$FRAME_LOG") >= 4 ))\n')
  stub("pkill", 'exit 0\n')
  stub("stty", 'echo "60 160"\n')
  stub("tty", 'echo /dev/pts/99\n')
  environment = dict(os.environ, HOME=str(home), OMARCHY_PATH=str(root), TMPDIR=str(scratch),
                     PATH=str(stubs) + ":" + str(root / "bin") + ":" + os.environ["PATH"],
                     FRAME_LOG=str(log), CALL_LOG=str(calls))

  def play(settings):
    config.write_text(json.dumps(settings))
    log.write_text("")
    calls.write_text("")
    result = subprocess.run([root / "bin/omarchy-screensaver"], env=environment,
                            stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
    check(result.returncode == 0, "screensaver exits on dismissal")
    check(not list(scratch.iterdir()), "dismissal removes playback copies")
    return log.read_text().splitlines()

  check(play({}) == ["DEFAULT"] * 4, "absent setting preserves default single-file playback")
  check(play({"screensaver": {"source": str(source / '01.txt')}}) == ["CHANGED"] * 4, "configured file plays through the runtime")
  check(play({"screensaver": {"source": str(source)}}) == ["CHANGED", "⣿⣿⣿", "LITERAL NAME", "CHANGED"], "runtime advances and wraps a collection")
  check(play({"screensaver": {"source": str(empty)}}) == ["DEFAULT"] * 4, "empty collection keeps the screensaver alive with its fallback")
  check(play({"screensaver": {"source": str(temp / 'missing')}}) == ["DEFAULT"] * 4, "missing source falls back instead of exiting")
  check(play({"screensaver": {"source": 42}}) == ["DEFAULT"] * 4, "invalid config type retains the default")
  stub("mktemp", 'exit 1\n')
  check(play({"screensaver": {"source": str(source)}}) == ["DEFAULT"] * 4, "temporary-directory failure retains playback")
  (stubs / "mktemp").unlink()
  stub("timeout", 'exit 124\n')
  check(play({"screensaver": {"source": str(source)}}) == ["DEFAULT"] * 4, "preparation timeout retains playback and cleans its directory")
  (stubs / "timeout").unlink()
  (branding / "screensaver.txt").unlink()
  play({"screensaver": {"source": str(empty)}})
  check(set(calls.read_text().splitlines()) == {str(root / 'logo.txt')}, "missing user fallback uses the bundled logo")
PY
