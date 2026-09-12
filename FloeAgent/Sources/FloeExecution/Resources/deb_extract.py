"""Extract a data-only Debian payload into a new directory, transactionally."""
import base64
import io
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile

NATIVE_MAGIC = {b"\x7fELF", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def extract_payload(payload, name, destination, max_entries=5000, max_bytes=256 * 1024 * 1024):
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        raise ValueError("Extraction requires a new destination directory")
    parent = destination.parent.resolve(strict=True)
    if str(parent) != str(destination.parent.absolute()):
        raise ValueError("Extraction destination contains a symbolic link")
    stage = Path(tempfile.mkdtemp(prefix=".floe-deb-", dir=parent))
    count = skipped = size = 0
    stream = io.BytesIO(payload)
    try:
        if name.endswith(".zst"):
            import zstandard
            stream = zstandard.ZstdDecompressor().stream_reader(stream)
        with tarfile.open(fileobj=stream, mode="r|*") as archive:
            for index, member in enumerate(archive, 1):
                if index > max_entries:
                    raise ValueError("Archive entry limit exceeded")
                relative = Path(member.name)
                if relative.is_absolute() or ".." in relative.parts or "\\" in member.name:
                    raise ValueError("Archive path escapes destination")
                target = stage / relative
                if member.issym() or member.islnk() or member.isdev():
                    skipped += 1
                    continue
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                if not member.isfile():
                    skipped += 1
                    continue
                size += member.size
                if member.size < 0 or size > max_bytes:
                    raise ValueError("Archive expanded size limit exceeded")
                source = archive.extractfile(member)
                if source is None:
                    raise ValueError("Archive member has no data")
                with source:
                    head = source.read(4)
                    if head in NATIVE_MAGIC:
                        raise ValueError("Archive contains native executable payload")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with target.open("xb") as output:
                        output.write(head)
                        shutil.copyfileobj(source, output, 65536)
                count += 1
        # The destination must still be absent; never replace an existing directory.
        if destination.exists() or destination.is_symlink():
            raise ValueError("Destination appeared during extraction")
        os.rename(stage, destination)
        return count, skipped
    finally:
        if stage.exists():
            shutil.rmtree(stage)
        stream.close()


if __name__ == "__main__":
    request = json.loads(input)
    count, skipped = extract_payload(base64.b64decode(request['payloadBase64'], validate=True), request['name'], request['destination'], request['maxEntries'], request['maxExpandedBytes'])
    print('files=' + str(count))
    print('skipped=' + str(skipped))
