# Scientific worker

The native App never starts a host interpreter. `BiologyWorkerResources.verifiedFiles()` supplies digest-checked scripts and dependency metadata. The separate [Floe host adapter](../Integration/FloeBiologyHostAdapter/README.md) probes the actual selected Linux environment and runs the worker through the existing `exec.shell` and durable job services. There is no new installer, language-specific execution alias or host fallback.

One bounded JSON request/reply carries project, object/revision/digest, task, host run, scientific run, attempt and environment. The host additionally verifies the actual job, stopped worker, processor exit, complete output length and digest. Imported content cannot grant authority. Large originals use an opaque reference, with exact bytes staged to a digest-named input under the trusted workspace passed by CLI `--workspace`; a JSON path is never accepted.

`requirements.lock` pins 66 packages, including Biopython, Gemmi, scikit-image/tifffile/Zarr, Scanpy/AnnData, SciPy, python-libsbml and libroadrunner 2.11.0. The lock records the actual CPython 3.12 macOS arm64 qualification environment. Platform wheel hashes/Linux availability and an end-to-end App Linux guest run are separate host checks. The runtime probe publishes only engines that really import and pass their functional probe; missing packages produce actionable diagnostics and do not invent available methods.

Run read-only checks with an explicitly selected qualification interpreter:

```sh
python -B verify_backend.py --check --runtime
python -B -m unittest -v test_science test_extensions
printf '{"operation":"capabilities"}' | python -B biology_worker.py
```

After reviewed script/dependency changes, explicitly regenerate `worker-manifest.json` with `python -B verify_backend.py --write-manifest`, then run `--check`. A check never repairs a lock or manifest. Production packages are installed through the existing resolved environment workflow, not these host test commands.

`dependency-licenses.json` retains metadata/license-file locations for all 66 external packages. No Python interpreter or library binary is linked into the native component. Preserve upstream license files when distributing a runtime. In particular, igraph/leidenalg have GPL terms; the native UI does not link them.

## Behavior and budgets

- 32 scientific methods, selected from the actual live engine probe. Current typed edits are authoritative for measurements; original export still preserves original bytes.
- TIFF/OME series and pyramid metadata are inspected without expanding the whole plane. Zarr regional reads cap output at 1 million pixels and one decompression chunk at 64 MiB. Segmentation coordinates refer to global level-0 pixels and calibrated physical coordinates, with selected C/Z/T/series/level/region retained. Multi-file OME stitching is not implemented.
- H5AD backed import limits expanded data to 128 MiB and 2 million values/nonzeros. MTX dimensions/nonzeros are checked before expansion. Native converted matrices also respect the dense budget.
- General SBML uses libSBML validation and real libRoadRunner/CVODE, explicit species amounts, fresh-model parameter sweeps, rate/assignment rules and events. Algebraic rules, delay differential equations, recursive functions and unsupported extension packages are rejected, never silently approximated. Limits: 128 species, 512 reactions, 128 rules/events/functions and 20,000 AST nodes/depth 64.
- Inline protocol: 32 MiB envelope, 16 MiB original, 4 million native image samples, 4 million alignment cells, 100,000 atoms and 200,000 contacts. File-backed originals have independent host storage limits; remote staging is streamed and is not a large-file throughput claim.
- Welch/BH comparisons treat cells as independent; biological replicate/covariate statistics, prediction, molecular dynamics and instrument control are outside this component.

Tests use numerical ground truth (translation/alignment, coordinate agreement, analytical trajectories/conservation, SBML rules/events, calibrated segmentation and foreign-file/digest rejection). Adapter contract fixtures validate ownership/jobs/cancellation separately; they do not count as real Linux scientific execution.
