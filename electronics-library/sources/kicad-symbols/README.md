# KiCad Symbols

This repository contains the official KiCad schematic symbol libraries.

**The libraries in this repository are intended for KiCad version 10.x**

Each symbol library is stored *unpacked* as a `.kicad_symdir` directory, each
containing multiple symbol files (also ending in `.kicad_sym`).

Contribution guidelines can be found at http://kicad.org/libraries/contribute
The library convention can be found at http://kicad.org/libraries/klc/

Other KiCad library repositories are located:

* Footprints: https://gitlab.com/kicad/libraries/kicad-footprints
* 3D Models: https://gitlab.com/kicad/libraries/kicad-packages3d
* Templates: https://gitlab.com/kicad/libraries/kicad-templates

## Packaging

This repository uses CMake to prepare the libraries for installation.

## Library packing

The libraries in this repository are in _unpacked_ format for ease of contribution and
version control. This means that each symbol is stored as a text-based `.kicad_sym` file
and each library is a directory containing multiple such files. A _packed_ library is a
single text-based `.kicad_sym` file containing all the symbols in that library.

It's recommended to _pack_ the libraries before use in KiCad for improved end-user
performance.

To pack the libraries, you will need to have CMake and Python installed.

To disable packing of the libraries, set the CMake option `KICAD_PACK_SYM_LIBRARIES` to
`OFF` when configuring the build.

## Building libraries

From the root of this repository, create a build directory and run CMake:

```bash
mkdir build
cd build
cmake .. -D KICAD_PACK_SYM_LIBRARIES=<ON|OFF>
```

Then build the libraries with:

```bash
cmake --build .
```

## Installation

You can install the prepared libraries with CMake:

```bash
cmake --build . -- install
```

Set `CMAKE_INSTALL_PREFIX` and `DESTDIR` as needed to control the installation location,
which will depend on your packaging system.
