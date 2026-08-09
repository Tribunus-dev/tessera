"""Test Intel lane dispatch keeping Apple lane intact."""

import numpy as np

from tools.tessera.calibration_metal import (
    BACKEND_MKL,
    BACKEND_NUMPY,
    BACKEND_SYCL_IGPU,
    MatmulBackend,
    get_matmul_backend_name,
    matmul,
    matmul_mkl,
    matmul_sycl,
)
from tools.tessera.intel_sharding import describe_residency, enumerate_intel_devices, sharded_chunked_matmul
from tools.tessera.intel_npu_quantizer import is_available as npu_is_available


def test_backend_names():
    name = get_matmul_backend_name()
    assert name in (BACKEND_NUMPY, BACKEND_MKL, BACKEND_SYCL_IGPU, "sycl-dgpu", "metal", "accelerate")


def test_mkl_correctness():
    a = np.random.randn(4, 8).astype(np.float32)
    b = np.random.randn(8, 4).astype(np.float32)
    expected = a @ b
    got = matmul_mkl(a, b)
    assert np.allclose(got, expected, atol=1e-5)


def test_sycl_correctness():
    a = np.random.randn(4, 8).astype(np.float32)
    b = np.random.randn(8, 4).astype(np.float32)
    expected = a @ b
    got = matmul_sycl(a, b)
    assert np.allclose(got, expected, atol=1e-5)


def test_sharded_correctness():
    chunks = [np.random.randn(4, 8).astype(np.float32) for _ in range(3)]
    b = np.random.randn(8, 4).astype(np.float32)
    results = sharded_chunked_matmul(chunks, b)
    for c, r in zip(chunks, results):
        assert np.allclose(r, c @ b, atol=1e-5)


def test_residency_describe():
    s = describe_residency()
    assert isinstance(s, str)
    assert "Intel" in s or "Heterogeneous" in s


def test_npu_probe():
    # Should not raise even when openvino absent
    available = npu_is_available()
    assert isinstance(available, bool)


def test_intel_headers_exist():
    import pathlib
    root = pathlib.Path(__file__).resolve().parents[2]
    assert (root / "tools/tessera/intel_mkl_matmul.cpp").exists()
    assert (root / "tools/tessera/intel_sycl_matmul.cpp").exists()
    assert (root / "tools/quantize/tessera/tessera-intel.h").exists()
