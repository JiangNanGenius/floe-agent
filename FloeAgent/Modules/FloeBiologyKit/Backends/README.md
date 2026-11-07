# Scientific worker

The native App never starts a host interpreter. `BiologyWorkerResources.verifiedFiles()` supplies digest-checked resources for the host's existing resolved Linux environment and package/job services. `ConfiguredBiologyBackend` requires a trusted transport and an acknowledged stop callback.

The worker reads one bounded JSON request from stdin and returns one JSON reply. Identity includes project, object/revision/digest, task, host run, scientific run, attempt and environment. A trusted host receipt must additionally identify the actual completed job. Imported content cannot grant authority.

`requirements.lock` records the exact CPython 3.12 macOS arm64 qualification environment. Versions are pinned; platform wheel hashes are not claimed. Linux wheels, installation, actual job cancellation and the App's environment lifecycle must be qualified by the integrating host. No automatic package installation or host fallback is supplied.

Run read-only integrity/version checks with the explicitly selected interpreter:

```sh
python -B verify_backend.py --check --runtime
python -B -m unittest -v test_science
printf '{"operation":"capabilities"}' | python -B biology_worker.py
```

After reviewed resource changes, regenerate the manifest explicitly with `python -B verify_backend.py --write-manifest`, then run `--check`. The check never repairs a lock or manifest.

`dependency-licenses.json` records upstream metadata and license-file locations for all 65 packages from that exact environment. Python packages/binaries are not bundled in the native component. Preserve their license files when packaging a runtime. In particular, igraph and leidenalg carry GPL terms; they are optional external analysis dependencies, not linked native UI libraries.

Limits: 32 MiB protocol envelopes, 16 MiB original files, 4 million image samples, 2 million dense values/nonzeros, 4 million alignment cells, 100,000 atoms, 200,000 contacts. Native matrix conversion has a dense budget even when remote sparse analysis is possible. Arbitrary SBML expressions are parsed for inspection and never executed; simulation uses the component's explicit mass-action model. Welch comparisons treat cells as independent and do not model biological replicates or covariates.
