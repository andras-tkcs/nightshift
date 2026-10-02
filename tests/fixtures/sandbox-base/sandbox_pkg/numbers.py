"""Number helpers."""


def mean(values):
    """Return the arithmetic mean of a non-empty sequence of numbers."""
    values = list(values)
    if not values:
        raise ValueError("mean() of an empty sequence")
    return sum(values) / len(values)
