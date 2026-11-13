#!/usr/bin/env python3
"""Install the pinned Linux x86-64 compiler inside this project; no system changes."""
import hashlib, pathlib, platform, tarfile, urllib.request
root=pathlib.Path(__file__).resolve().parents[1]/'.tools'
if platform.system()!='Linux' or platform.machine() not in ('x86_64','AMD64'):
    raise SystemExit('Install Zig 0.15.2 from https://ziglang.org/download/ and set ZIG=/path/to/zig')
if (root/'zig/zig').exists():raise SystemExit(0)
root.mkdir(exist_ok=True)
archive=root/'zig-0.15.2.tar.xz'
url='https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz'
print('Downloading Zig 0.15.2 (54 MB), local to this project.',flush=True)
if not archive.exists():urllib.request.urlretrieve(url,archive)
if hashlib.sha256(archive.read_bytes()).hexdigest()!='02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239':
    archive.unlink();raise SystemExit('Compiler checksum mismatch; download removed.')
with tarfile.open(archive) as t:
    try:t.extractall(root,filter='data')
    except TypeError:t.extractall(root) # Archive was verified against a pinned digest.
(root/'zig-x86_64-linux-0.15.2').rename(root/'zig')
archive.unlink()
print('Compiler checksum verified.',flush=True)
