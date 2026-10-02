import pytest

from sandbox_pkg.numbers import mean


def test_mean():
    assert mean([1, 2, 3]) == 2.0


def test_mean_empty():
    with pytest.raises(ValueError):
        mean([])
