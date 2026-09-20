# Office dependency rebuilt for Build206

[Native host run35495484711](https://github.com/JiangNanGenius/floe-agent/actions/runs/35495484711)
succeeded at source `f2d3ae37ba321d47201798099d2c8a38de1d11ed` (the same
Office sources rejected by Build205's old dependency pin). Native framework
compile/link and Swift import passed. This is not an App/device acceptance result.

Artifact `office-native-host-unsigned`, ID10599654752:

- Inner `OfficeNativeHost.zip` SHA256: `2d0afe5150c6914b37add4031aaad4fbd96db47dca8e1c1008d25db8d87a12e0`.
- Framework executable SHA256: `e59f12780e47c72edd359c830881ccc282044cfada4e6a28aef2e0c2d0bdc4b2`.
- Manifest SHA256: `8d18da2345892dfbf098ac114b43d7c2c1e638633e3e15ea40088b338aeef39a`.

The downloaded manifest's four host source hashes match the current source;
engine commit, overlay and filter source pins remain unchanged. Rebuilt archive
member metadata changed archive hashes while the filter object hashes stayed
the same. Framework headers and auxiliary file hashes were measured from the
new archive. The real `bootstrap_office_host.py --archive ...` verified all
4,785 files and 178 directories, installed the host and generated project inputs
without downloading or compiling an App locally. `engine.lock.json` now records
the measured artifact. No check was bypassed.
