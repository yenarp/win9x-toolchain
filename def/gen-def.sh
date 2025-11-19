#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DLL_DIR="${SCRIPT_DIR}/dlls"
OUT_DIR="${SCRIPT_DIR}/generated"

FORCE=0
VERBOSE=0
while [[ $# -gt 0 ]]; do
	case "$1" in
	-f | --force) FORCE=1 ;;
	-v | --verbose) VERBOSE=1 ;;
	-h | --help)
		echo "Usage: $0 [-f|--force] [-v|--verbose]"
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		exit 2
		;;
	esac
	shift
done

log() { [[ $VERBOSE -eq 1 ]] && echo "$*"; }

if ! command -v file >/dev/null 2>&1; then
	echo "Error: 'file' command is required." >&2
	exit 1
fi

HAVE_GENDEF=0
HAVE_PEXPORTS=0
command -v gendef >/dev/null 2>&1 && HAVE_GENDEF=1
command -v pexports >/dev/null 2>&1 && HAVE_PEXPORTS=1

if [[ $HAVE_GENDEF -eq 0 && $HAVE_PEXPORTS -eq 0 ]]; then
	echo "Error: need either 'gendef' (preferred) or 'pexports' in PATH." >&2
	exit 1
fi
mkdir -p "${OUT_DIR}"

is_pe32() {
	local f="$1" desc
	desc="$(file -b "$f" || true)"

	grep -Eiq 'PE32[^,]*executable.*DLL' <<<"$desc"
}

has_exports() {
	objdump -p "$1" 2>/dev/null | grep -qi 'Export Table'
}

gen_with_gendef() {
	local dll="$1" out_tmp="$2" base="$3"
	local tdir
	tdir="$(mktemp -d)"

	if ! (cd "$tdir" && gendef "$dll" >/dev/null 2>&1); then
		rm -rf "$tdir"
		return 1
	fi

	local produced
	produced="$(find "$tdir" -maxdepth 1 -type f -iname '*.def' | head -n1 || true)"
	if [[ -z "$produced" ]]; then
		rm -rf "$tdir"
		return 1
	fi

	{
		echo "LIBRARY ${base}"
		echo "EXPORTS"
		sed -e 's/\r$//' \
			-e '/^[[:space:]]*;/d' \
			-e '/^[[:space:]]*$/d' \
			-e '/^[[:space:]]*LIBRARY[[:space:]]/Id' \
			-e '/^[[:space:]]*EXPORTS[[:space:]]*$/Id' \
			"$produced"
	} >"$out_tmp"
	rm -rf "$tdir"

	[[ $(grep -c -v -E '^(LIBRARY|EXPORTS)$' "$out_tmp") -gt 0 ]]
}

gen_with_pexports() {
	local dll="$1" out_tmp="$2" base="$3"
	local raw
	raw="$(mktemp)"
	if ! pexports "$dll" >"$raw" 2>/dev/null; then
		rm -f "$raw"
		return 1
	fi
	{
		echo "LIBRARY ${base}"
		echo "EXPORTS"
		sed -e 's/\r$//' \
			-e '/^[[:space:]]*;/d' \
			-e '/^[[:space:]]*$/d' \
			-e 's/^[[:space:]]*//' \
			"$raw"
	} >"$out_tmp"
	rm -f "$raw"
	[[ $(grep -c -v -E '^(LIBRARY|EXPORTS)$' "$out_tmp") -gt 0 ]]
}

shopt -s nullglob nocaseglob
mapfile -d '' DLLS < <(find "${DLL_DIR}" -type f -iname '*.dll' -print0)
shopt -u nocaseglob

[[ ${#DLLS[@]} -gt 0 ]] || {
	echo "No DLLs found in ${DLL_DIR}" >&2
	exit 1
}

total=${#DLLS[@]}
gen=0
skip=0
err=0

for dll in "${DLLS[@]}"; do
	basefile="$(basename "$dll")"
	base="${basefile%.*}.DLL"
	out="${OUT_DIR}/$(echo "${base%.*}" | tr '[:upper:]' '[:lower:]').def"

	if ! is_pe32 "$dll"; then
		log "skip (not PE32 DLL): $basefile"
		((skip++)) || true
		continue
	fi
	if [[ $FORCE -eq 0 && -f "$out" && "$out" -nt "$dll" ]]; then
		log "up-to-date: $basefile -> $(basename "$out")"
		((skip++)) || true
		continue
	fi

	tmp="$(mktemp)"
	ok=1
	if [[ $HAVE_GENDEF -eq 1 ]]; then
		gen_with_gendef "$dll" "$tmp" "$base" && ok=0
	fi

	if [[ $ok -ne 0 && $HAVE_PEXPORTS -eq 1 ]]; then
		gen_with_pexports "$dll" "$tmp" "$base" && ok=0
	fi

	if [[ $ok -ne 0 ]]; then
		if has_exports "$dll"; then
			echo "FAIL: could not extract exports for $basefile (tool error)" >&2
			rm -f "$tmp"
			((err++)) || true
		else
			log "skip (no exports): $basefile"
			rm -f "$tmp"
			((skip++)) || true
		fi
		continue
	fi

	mv -f "$tmp" "$out"
	log "gen: $basefile -> $(basename "$out")"
	((gen++)) || true
done

echo "Done. Total: $total, generated: $gen, skipped: $skip, errors: $err"
