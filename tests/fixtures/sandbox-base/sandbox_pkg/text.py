"""Text helpers."""


def reverse_words(text):
    """Return the words of text in reverse order, joined by single spaces."""
    return " ".join(reversed(text.split()))


def count_vowels(text):
    """Return the number of vowels in text."""
    return sum(1 for ch in text if ch in "aeiou")
