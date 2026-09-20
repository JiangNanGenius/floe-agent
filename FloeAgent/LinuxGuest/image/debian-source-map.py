#!/usr/bin/env python3
"""debian-source-map.py — build the binary-package -> source-package mapping for
an installed Debian userland and download the corresponding source packages.

Why this exists: the Floe guest image is a modified, Floe-hosted image, so
"the user could download it from Debian" is not an exemption. Every installed
binary package must be traceable to its exact source package version and the
Debian source files (.dsc + orig + debian tarballs) must be obtainable and
verifiable.

Subcommands:

  index  --suite NAME=URL ... --out DIR
      Download each `Sources.xz` index and record it in DIR/indexes.tsv with
      its SHA-256. Nothing else is fetched.

  map    --packages guest-packages.tsv --index-dir DIR --out mapping.tsv --gaps gaps.txt
      guest-packages.tsv is the `dpkg-query -W` dump written by the image
      build:
        binary <TAB> binaryVersion <TAB> arch <TAB> source <TAB> sourceVersion
      Emits one row per binary package:
        binary <TAB> binaryVersion <TAB> source <TAB> sourceVersion <TAB> suite
        <TAB> poolBase <TAB> directory <TAB> file <TAB> sha256 <TAB> size
      Packages whose source version is not in the downloaded indexes are
      written to the gaps file (and make `map` exit 3 unless --allow-gaps).

  fetch  --mapping mapping.tsv --out DIR --checksums SOURCES.sha256
      Download every referenced file from its pool base, verify size and
      SHA-256, and write the checksum list. Already-verified files are reused,
      so a retry does not re-download the whole set.

The Sources index is the archive's own metadata; the URL + SHA-256 recorded by
`index` is what makes the mapping reviewable later, when Debian rotates
mirrors.
"""
import argparse
import hashlib
import lzma
import os
import re
import sys
import urllib.request

GAP_EXIT = 3


def normalize_version(version):
    """Strip a leading Debian epoch: dpkg shows binary epochs that Debian's
    Sources index may omit for the source package (`1:2.41.5-0+deb13u1` vs
    `2.41.5-0+deb13u1`)."""
    return re.sub(r"^[0-9]+:", "", version.strip())


def base_version(version):
    """Normalized version without a binary-only rebuild suffix (`+b1`)."""
    return re.sub(r"\+b[0-9]+$", "", normalize_version(version))


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def pool_base(url):
    """Derive the archive root (pool base) from a Sources.xz URL."""
    marker = "/dists/"
    index = url.find(marker)
    if index < 0:
        raise SystemExit("cannot derive the pool base from %s" % url)
    return url[:index]


def parse_sources(path):
    """Yield dicts for each source package entry in a Sources index."""
    with lzma.open(path, "rt", encoding="utf-8", errors="replace") as handle:
        entry = {}
        field = None
        for raw in handle:
            line = raw.rstrip("\n")
            if not line:
                if entry:
                    yield entry
                entry = {}
                field = None
                continue
            if line[0] in " \t":
                if field:
                    entry.setdefault(field, []).append(line.strip())
                continue
            if ":" not in line:
                continue
            name, value = line.split(":", 1)
            field = name.strip()
            entry[field] = [value.strip()]
        if entry:
            yield entry


def entry_sha256(entry):
    """Map filename -> (sha256, size) from Checksums-Sha256."""
    result = {}
    for line in entry.get("Checksums-Sha256", []):
        parts = line.split()
        if len(parts) >= 3:
            result[parts[2]] = (parts[0], int(parts[1]))
    return result


def suite_rank(suite):
    if "security" in suite:
        return 3
    if "updates" in suite or "backports" in suite:
        return 2
    return 1


def cmd_index(args):
    os.makedirs(args.out, exist_ok=True)
    rows = []
    for spec in args.suite:
        if "=" not in spec:
            raise SystemExit("--suite must be NAME=URL, got %r" % spec)
        name, url = spec.split("=", 1)
        target = os.path.join(args.out, "%s.Sources.xz" % name)
        print("index: %s -> %s" % (url, target))
        with urllib.request.urlopen(url, timeout=300) as response, open(target, "wb") as handle:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                handle.write(chunk)
        rows.append((name, url, sha256_file(target), os.path.basename(target), pool_base(url)))
    with open(os.path.join(args.out, "indexes.tsv"), "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write("\t".join(row) + "\n")
    print("wrote %s/indexes.tsv (%d indexes)" % (args.out, len(rows)))
    return 0


def load_indexes(index_dir):
    """Return (entries, suites): entries maps (name, version) -> best record."""
    indexes_path = os.path.join(index_dir, "indexes.tsv")
    if not os.path.isfile(indexes_path):
        raise SystemExit("no indexes.tsv in %s; run `index` first" % index_dir)
    entries = {}
    suites = []
    with open(indexes_path, "r", encoding="utf-8") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 5:
                continue
            suite, url, sha, filename, base = parts
            suites.append({"suite": suite, "url": url, "sha256": sha, "base": base})
            path = os.path.join(index_dir, filename)
            if not os.path.isfile(path):
                raise SystemExit("index file missing: %s" % path)
            if sha256_file(path) != sha:
                raise SystemExit("index file %s does not match its recorded sha256" % path)
            for entry in parse_sources(path):
                name = (entry.get("Package") or [""])[0].strip()
                version = (entry.get("Version") or [""])[0].strip()
                directory = (entry.get("Directory") or [""])[0].strip()
                if not name or not version or not directory:
                    continue
                checksums = entry_sha256(entry)
                files = []
                for filename2, (file_sha, size) in sorted(checksums.items()):
                    files.append({"file": filename2, "sha256": file_sha, "size": size})
                if not files:
                    continue
                record = {
                    "source": name,
                    "version": version,
                    "suite": suite,
                    "base": base,
                    "directory": directory,
                    "files": files,
                    "binaries": [b.strip() for b in ",".join(entry.get("Binary", [])).split(",") if b.strip()],
                }
                key = (name.lower(), normalize_version(version))
                current = entries.get(key)
                if current is None or suite_rank(suite) > suite_rank(current["suite"]):
                    entries[key] = record
    # Binary-name fallback: `dpkg-query` normally records the source package,
    # but a missing/renamed field must not fabricate a gap when the index
    # itself says which source produced the binary.
    by_binary = {}
    for record in entries.values():
        for binary in record["binaries"]:
            by_binary.setdefault(binary.lower(), []).append(record)
    return entries, suites, by_binary


def binary_version_matches(record, binary_version):
    """True when a source version corresponds to a binary version (epoch /
    binary-only rebuild differences tolerated)."""
    return (normalize_version(record["version"]) == normalize_version(binary_version)
            or base_version(record["version"]) == base_version(binary_version))


def cmd_map(args):
    entries, suites, by_binary = load_indexes(args.index_dir)
    if not os.path.isfile(args.packages):
        raise SystemExit("package list not found: %s" % args.packages)
    rows = []
    gaps = []
    seen_sources = {}
    with open(args.packages, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 5:
                continue
            binary, binary_version, arch, source, source_version = parts[:5]
            if not binary:
                continue
            # `${binary:Package}` can carry a `:arch` multi-arch qualifier.
            binary = binary.split(":")[0]
            source = source.split(":")[0]
            if not source:
                source = binary
            if not source_version:
                source_version = binary_version
            record = entries.get((source.lower(), normalize_version(source_version)))
            if record is None:
                # Binary-only updates can leave source:Version at the base
                # version; try the binary version before falling back.
                record = entries.get((source.lower(), normalize_version(binary_version)))
            if record is None:
                # Last resort: the index's own Binary: field for this exact
                # binary version (never guessed across versions).
                candidates = [r for r in by_binary.get(binary.lower(), [])
                              if binary_version_matches(r, binary_version)]
                if candidates:
                    record = max(candidates, key=lambda r: suite_rank(r["suite"]))
            if record is None:
                gaps.append((binary, binary_version, source, source_version))
                continue
            seen_sources[(record["source"], record["version"])] = record
            for file_entry in record["files"]:
                rows.append((
                    binary, binary_version, record["source"], record["version"], record["suite"],
                    record["base"], record["directory"], file_entry["file"],
                    file_entry["sha256"], str(file_entry["size"]),
                ))
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write("#binary\tbinary_version\tsource\tsource_version\tsuite\tpool_base\tdirectory\tfile\tsha256\tsize\n")
        for row in rows:
            handle.write("\t".join(row) + "\n")
    with open(args.gaps, "w", encoding="utf-8") as handle:
        handle.write("#binary\tbinary_version\tsource\tsource_version\n")
        for gap in gaps:
            handle.write("\t".join(gap) + "\n")
    print("mapped %d binary packages to %d source packages; %d file downloads; %d gaps"
          % (len({r[0] for r in rows} | {g[0] for g in gaps}), len(seen_sources), len(rows), len(gaps)))
    if suites:
        print("indexes: " + ", ".join("%s(%s)" % (s["suite"], s["sha256"][:12]) for s in suites))
    if gaps and not args.allow_gaps:
        print("unmapped packages (see %s):" % args.gaps, file=sys.stderr)
        for gap in gaps[:20]:
            print("  %s %s -> %s %s" % gap, file=sys.stderr)
        if len(gaps) > 20:
            print("  ... %d more" % (len(gaps) - 20), file=sys.stderr)
        return GAP_EXIT
    return 0


def download(url, target, expected_sha256, expected_size):
    if os.path.isfile(target):
        if os.path.getsize(target) == expected_size and sha256_file(target) == expected_sha256:
            return "cached"
    part = target + ".part"
    request = urllib.request.Request(url, headers={"User-Agent": "floe-component-image-ci/1"})
    with urllib.request.urlopen(request, timeout=600) as response, open(part, "wb") as handle:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            handle.write(chunk)
    size = os.path.getsize(part)
    if size != expected_size:
        os.unlink(part)
        raise SystemExit("size mismatch for %s: %d != %d" % (url, size, expected_size))
    digest = sha256_file(part)
    if digest != expected_sha256:
        os.unlink(part)
        raise SystemExit("sha256 mismatch for %s: %s != %s" % (url, digest, expected_sha256))
    os.replace(part, target)
    return "downloaded"


def cmd_fetch(args):
    os.makedirs(args.out, exist_ok=True)
    seen = {}
    with open(args.mapping, "r", encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("#"):
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 10:
                continue
            _, _, source, source_version, _, base, directory, filename, sha, size = parts[:10]
            key = (base, directory, filename)
            seen[key] = (source, source_version, sha, int(size))
    print("fetch: %d unique source files" % len(seen))
    # Shard the downloads so no single GitHub artifact has to carry the whole
    # set. Files are packed largest-first into the currently smallest shard,
    # which is deterministic for a given mapping file.
    order = sorted(seen.items(), key=lambda item: (-item[1][3], item[0][2]))
    shard_count = 1
    shard_bytes = [0]
    shard_of = {}
    for key, (_, _, _, size) in order:
        target_index = min(range(shard_count), key=lambda i: shard_bytes[i])
        if shard_bytes[target_index] + size > args.shard_bytes and target_index == shard_count - 1 and args.shard_bytes > 0:
            shard_count += 1
            shard_bytes.append(0)
            target_index = shard_count - 1
        shard_bytes[target_index] += size
        shard_of[key] = target_index + 1
    total = 0
    checksums = []
    source_files = {}
    for (base, directory, filename), (source, source_version, sha, size) in sorted(seen.items()):
        shard = shard_of[(base, directory, filename)]
        shard_dir = os.path.join(args.out, "shard-%d" % shard)
        os.makedirs(shard_dir, exist_ok=True)
        target = os.path.join(shard_dir, filename)
        status = download("%s/%s/%s" % (base.rstrip("/"), directory, filename), target, sha, size)
        total += size
        relative = "shard-%d/%s" % (shard, filename)
        checksums.append((sha, relative))
        source_files.setdefault((source, source_version), []).append(relative)
        print("  %-9s %s (%d bytes)" % (status, relative, size))
    with open(args.checksums, "w", encoding="utf-8") as handle:
        for sha, relative in checksums:
            handle.write("%s  %s\n" % (sha, relative))
    sources_tsv = os.path.join(args.out, "SOURCES.tsv")
    with open(sources_tsv, "w", encoding="utf-8") as handle:
        handle.write("#source\tsource_version\tfiles\n")
        for (source, source_version), files in sorted(source_files.items()):
            handle.write("%s\t%s\t%s\n" % (source, source_version, ",".join(sorted(files))))
    for index, size in enumerate(shard_bytes, start=1):
        print("shard-%d: %d bytes" % (index, size))
    print("fetched %d files (%d bytes total); checksums in %s" % (len(checksums), total, args.checksums))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    index = sub.add_parser("index", help="download Sources.xz indexes")
    index.add_argument("--suite", action="append", required=True, help="NAME=URL (repeatable)")
    index.add_argument("--out", required=True)
    index.set_defaults(func=cmd_index)

    mapping = sub.add_parser("map", help="map installed binary packages to source packages")
    mapping.add_argument("--packages", required=True)
    mapping.add_argument("--index-dir", required=True)
    mapping.add_argument("--out", required=True)
    mapping.add_argument("--gaps", required=True)
    mapping.add_argument("--allow-gaps", action="store_true")
    mapping.set_defaults(func=cmd_map)

    fetch = sub.add_parser("fetch", help="download and verify the corresponding source files")
    fetch.add_argument("--mapping", required=True)
    fetch.add_argument("--out", required=True)
    fetch.add_argument("--checksums", required=True)
    fetch.add_argument("--shard-bytes", type=int, default=1200 * 1024 * 1024,
                       help="target maximum bytes per source shard directory (0 = one shard)")
    fetch.set_defaults(func=cmd_fetch)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
