# Biology sample inputs

RCSB originals retain exact downloaded bytes, including fixed-column/trailing
padding. Local attributes disable line-ending normalization and only the
end-of-line padding warning for those two files; manifest hashes stay authoritative.

The standalone workbench uses small offline examples. The `sample-index.json`
manifest records each exact input's origin, byte count, SHA-256 and license.
`BiologySamples.data(for:)` validates the bundled bytes before returning them.

- `1ubq.pdb` and `1ubq.cif`: the experimentally determined ubiquitin structure
  from [RCSB PDB entry 1UBQ](https://www.rcsb.org/structure/1UBQ), retrieved on
  2026-11-07. The original structure files retain the authors' bibliographic
  records. PDB archive data are available under CC0-1.0; see the
  [RCSB usage policy](https://www.rcsb.org/pages/policies#References).
- `synthetic-dna.fasta`: two short synthetic teaching sequences with no organism
  assignment. They support observable comparison, translation and save/export.
- `synthetic-counts.csv`: a synthetic six-gene, eight-cell count matrix with an
  explicit gene-row/cell-column orientation and two labelled groups. These are
  teaching values, not experimental measurements.
- `synthetic-microscopy.json` and `.pgm`: a synthetic 64 × 64 single-channel,
  16-bit image with two objects and a 0.5 micrometer pixel size. The JSON stores
  numeric intensities 0/25/60; the PGM intensities are scaled by 1000. Both have
  the same geometry. Neither is a microscope acquisition.
- `synthetic-network.json`: a two-species, first-order conversion with a known
  analytical solution and conserved total. The amounts are in arbitrary units
  and time is in seconds.

- `synthetic-tree.newick`: a small synthetic multifurcating teaching tree with branch lengths.
- `synthetic-density.mrc`: a synthetic scalar field with physical grid metadata for slice/isosurface inspection; it is not an experimental density reconstruction.

Floe's synthetic fixtures and resource wrapper use MPL-2.0. Bundling examples
does not establish general format, scientific-method or physical-device
acceptance; those are checked separately in the qualification evidence.
