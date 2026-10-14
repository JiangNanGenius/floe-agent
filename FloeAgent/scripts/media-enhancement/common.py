#!/usr/bin/env python3
"""Shared helpers for the Floe media-enhancement Core ML conversion.

Not a runtime dependency: conversion-host only (Local/Scratch venv).
"""
from __future__ import annotations

import hashlib
import json
import pathlib

import numpy as np

# Fixed reference seed so the PyTorch reference and the Core ML output are
# compared on byte-identical inputs across runs.
REFERENCE_SEED = 20261014


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: pathlib.Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def max_mean_abs_diff(reference: np.ndarray, candidate: np.ndarray) -> dict:
    reference = np.asarray(reference, dtype=np.float64)
    candidate = np.asarray(candidate, dtype=np.float64)
    if reference.shape != candidate.shape:
        raise ValueError(f"shape mismatch: {reference.shape} != {candidate.shape}")
    diff = np.abs(reference - candidate)
    mse = float(np.mean(diff ** 2))
    return {
        "maxAbsDiff": float(diff.max()),
        "meanAbsDiff": float(diff.mean()),
        "rmse": float(np.sqrt(mse)),
        "psnr": float("inf") if mse == 0 else float(10.0 * np.log10(1.0 / mse)),
        "shape": list(reference.shape),
    }


def normalize_to_unit(array: np.ndarray) -> np.ndarray:
    """Scale any 0..255 float array to 0..1 for PSNR-style comparison."""
    array = np.asarray(array, dtype=np.float32)
    return array / 255.0 if float(array.max()) > 1.5 else array
