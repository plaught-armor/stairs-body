#!/usr/bin/env bash
# Runs the headless StairsCharacter suite. Exit code is the number of failures.
#
# Godot is not on PATH on this machine, so point GODOT at a binary if none of the
# candidates below exist:
#
#     GODOT=/path/to/godot test/run.sh
set -euo pipefail

# Tried in order. The source build leads because it is the newest, but it also
# DISAPPEARS while it is being rebuilt - bin/ holds only the object files for the
# length of a compile - and a run.sh that dies for those minutes is a run.sh
# nobody trusts. The stable downloads are the fallback, and the suite passes
# identically on all of them.
CANDIDATES=(
	/mnt/based_backup/Repos/godot/bin/godot.linuxbsd.editor.x86_64
	/mnt/based_backup/Repos/godot47/Godot_v4.7-stable_linux.x86_64
	/mnt/based_backup/Repos/godot/bin/Godot_v4.6-stable_linux.x86_64
)

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${GODOT:-}" ]]; then
	for candidate in "${CANDIDATES[@]}"; do
		if [[ -x "$candidate" ]]; then
			GODOT="$candidate"
			break
		fi
	done
fi

if [[ -z "${GODOT:-}" || ! -x "$GODOT" ]]; then
	echo "No Godot binary found. Tried:" >&2
	printf '  %s\n' "${CANDIDATES[@]}" >&2
	echo "Set GODOT=/path/to/godot to override." >&2
	exit 127
fi

echo "Using $GODOT"

# The global class cache lives in .godot/, so class_name StairsCharacter does
# not resolve until the project has been imported at least once.
if [[ ! -f "$PROJECT/.godot/global_script_class_cache.cfg" ]]; then
	echo "Importing project (first run)..."
	"$GODOT" --headless --path "$PROJECT" --import >/dev/null
fi

"$GODOT" --headless --path "$PROJECT" res://test/test_stairs.tscn
