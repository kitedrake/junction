#!/bin/sh
# Refreshes the bundled headphone library (Resources/HeadphoneLibrary/database_v1.jsonl.lzma) from the open headphone
# EQ database's mirror, for the owner to run by hand before a release:
#   sh scripts/update-headphone-library.sh            # downloads https://opra.roonlabs.net/database_v1.jsonl
#   sh scripts/update-headphone-library.sh file.jsonl # uses a copy already downloaded
# It checks that every line parses and the counts are sane, compresses it with compression_tool (LZMA, which
# Foundation reads), checks the compressed file decodes to the same bytes, and rewrites SOURCE.md's description with
# the date, size, SHA-256 and counts. Nothing is replaced unless every step passes. Afterwards, update what the code and
# tests hold about the bundled copy (it prints the list), then run ./test.sh.
set -eu
cd "$(dirname "$0")/.."
mirror="https://opra.roonlabs.net/database_v1.jsonl"
folder=Resources/HeadphoneLibrary
tmp="$(mktemp -d "${TMPDIR:-/tmp}/junction-library.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

if [ $# -gt 0 ]; then
  cp "$1" "$tmp/database_v1.jsonl"
  date="$(date -u -r "$1" +%Y-%m-%d)"
else
  echo "Downloading $mirror"
  curl -fsSL --retry 2 --connect-timeout 30 -o "$tmp/database_v1.jsonl" "$mirror"
  date="$(date -u +%Y-%m-%d)"
fi

# Check it and write the new SOURCE.md next to it (nothing in the repository changes yet).
python3 -I - "$tmp/database_v1.jsonl" "$folder/SOURCE.md" "$tmp/SOURCE.md" "$date" "$mirror" <<'PYTHON'
import collections, hashlib, json, sys, textwrap

path, source, output, date, mirror = sys.argv[1:]
data = open(path, "rb").read()
if not data.endswith(b"\n"):
    sys.exit("The file ends in the middle of a line: incomplete download?")
counts = collections.Counter()
authors = collections.Counter()
for number, line in enumerate(data.split(b"\n"), 1):
    if not line.strip():
        continue
    try:
        entry = json.loads(line)
        kind, body = entry["type"], entry["data"]
    except (ValueError, KeyError, TypeError):
        sys.exit(f"Line {number} can't be read.")
    if kind == "eq" and body.get("type", "parametric_eq") != "parametric_eq":
        kind = "other eq"
    counts[kind] += 1
    if kind == "eq":
        authors[body.get("author") or "unknown"] += 1
if counts["product"] < 1000 or counts["eq"] < 1000:
    sys.exit(f"Only {counts['product']} products and {counts['eq']} parametric EQ presets: not a full database?")

sha = hashlib.sha256(data).hexdigest()
top = ", ".join(f"{name} {count:,}" for name, count in authors.most_common(3))
paragraph = (
    "`database_v1.jsonl.lzma` is the OPRA headphone EQ database (https://github.com/opra-project/OPRA), the "
    f"`database_v1.jsonl` file its mirror ({mirror}) served on {date}, compressed with LZMA (xz container, as "
    f"Apple's Compression framework reads it). Uncompressed: {len(data):,} bytes, SHA-256 `{sha}`. It lists "
    f"{counts['vendor']:,} vendors, {counts['product']:,} products and {counts['eq']:,} parametric EQ presets ({top})."
)
parts = open(source, encoding="utf-8").read().split("\n\n")
if len(parts) < 2 or not parts[1].startswith("`database_v1.jsonl.lzma` is"):
    sys.exit(f"{source} doesn't start the way this script expects; update it by hand.")
parts[1] = textwrap.fill(paragraph, width=118, break_long_words=False, break_on_hyphens=False)
open(output, "w", encoding="utf-8").write("\n\n".join(parts))
print(f"{len(data):,} bytes, SHA-256 {sha}")
print(f"{counts['vendor']:,} vendors, {counts['product']:,} products, {counts['eq']:,} parametric EQ presets"
      + (f", {counts['other eq']:,} other EQ presets" if counts["other eq"] else ""))
PYTHON

compression_tool -encode -a lzma -i "$tmp/database_v1.jsonl" -o "$tmp/database_v1.jsonl.lzma"
compression_tool -decode -a lzma -i "$tmp/database_v1.jsonl.lzma" -o "$tmp/check.jsonl"
cmp -s "$tmp/database_v1.jsonl" "$tmp/check.jsonl" || { echo "The compressed copy doesn't decode to the same file." >&2; exit 1; }

mv "$tmp/database_v1.jsonl.lzma" "$folder/database_v1.jsonl.lzma"
mv "$tmp/SOURCE.md" "$folder/SOURCE.md"
echo "Updated $folder/database_v1.jsonl.lzma and SOURCE.md (data of $date)."
echo "Now update what the code and tests hold about the bundled copy, then run ./test.sh:"
echo "  - HeadphoneLibrary.bundledDate and bundledSize (Sources/JunctionCore/HeadphoneLibrary.swift)"
echo "  - the counts in HeadphoneLibraryTests and HeadphoneLibraryUpdateTests, and bundledSHA256 there"
