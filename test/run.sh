#!/usr/bin/env bash
# Runs the headless StairsCharacter suite. Exit code is the number of failures.
#
# Godot is not on PATH on this machine, so point GODOT at a binary if the
# default local build moves:
#
#     GODOT=/path/to/godot test/run.sh
set -euo pipefail

GODOT="${GODOT:-/mnt/based_backup/Repos/godot/bin/godot.linuxbsd.editor.x86_64}"
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -x "$GODOT" ]]; then
	echo "Godot binary not found or not executable: $GODOT" >&2
	exit 127
fi

# The global class cache lives in .godot/, so class_name StairsCharacter does
# not resolve until the project has been imported at least once.
if [[ ! -f "$PROJECT/.godot/global_script_class_cache.cfg" ]]; then
	echo "Importing project (first run)..."
	"$GODOT" --headless --path "$PROJECT" --import >/dev/null
fi

"$GODOT" --headless --path "$PROJECT" res://test/test_stairs.tscn
