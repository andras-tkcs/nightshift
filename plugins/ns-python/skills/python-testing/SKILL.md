---
name: python-testing
description: Use when editing Python files that have or need pytest tests, to write tests the Nightshift way.
user-invocable: false
---

# Python testing

Apply these when you add or change tests in a Python project. If the
project already has testing conventions, follow them first.

## Workflow

1. Write the failing test first. Run it and see it fail for the
   expected reason before you write the code.
2. Make it pass with the smallest change.
3. Run the whole suite (`python -m pytest -q`), not only the new test.

## Rules

- Use pytest, plain `assert` statements and plain test functions.
  Do not add `unittest.TestCase` classes to a pytest suite.
- One behaviour per test. Name the test after the behaviour, for
  example `test_parse_rejects_empty_input`.
- Prefer fixtures over setup code repeated in tests. Keep shared
  fixtures in `conftest.py` and give them the narrowest scope that
  works.
- Use the `tmp_path` fixture for files and directories. Never write
  into the repository or the home directory from a test.
- Unit tests make no network calls. Fake the boundary with
  `monkeypatch` or a small stub, and keep any real network test behind
  an explicit marker that is off by default.
- Use `pytest.mark.parametrize` for the same behaviour over several
  inputs, and `pytest.raises` for expected errors.
- Do not depend on test order, wall-clock time or random values. Pass
  clocks and seeds in.

## Acceptance tests written before the code

When a test describes behaviour that does not exist yet, mark it
`@pytest.mark.xfail(strict=True, reason="...")`. With `strict=True` the
suite fails as soon as the test starts passing, which reminds you to
remove the marker in the same change that implements the behaviour.

## Do not

- Do not delete or loosen a failing test to get a green run. Fix the
  code or report the disagreement.
- Do not skip a test without a reason string.
