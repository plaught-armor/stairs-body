#!/usr/bin/env bash
# Runs the headless StairsBody suites. Exit code is the total
# number of failures.
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

# StairsBody is a GDExtension; build it first with `scons` at the repo root.
if ! compgen -G "$PROJECT/addons/stairs-body/bin/libstairsbody.*" >/dev/null; then
	echo "No StairsBody library in addons/stairs-body/bin. Run scons at the repo root." >&2
	exit 127
fi

# An extension only loads once an import has listed it in .godot/, which a fresh
# clone does not have.
if ! grep -qs stairs_body.gdextension "$PROJECT/.godot/extension_list.cfg"; then
	echo "Importing project to register StairsBody..."
	"$GODOT" --headless --path "$PROJECT" --import >/dev/null
fi

# Every suite runs even when an earlier one fails, and the exit code is the total.
failed=0
for scene in test_stairs.tscn test_stairs_body.tscn; do
	status=0
	"$GODOT" --headless --path "$PROJECT" "res://test/$scene" || status=$?
	failed=$((failed + status))
done
exit "$failed"
