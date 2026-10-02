---
name: python-packaging
description: Use when editing Python files or project metadata that affect packaging, dependencies, virtualenvs or PyInstaller builds.
user-invocable: false
---

# Python packaging

Apply these when you touch dependencies, project metadata, install
steps or build specs. If the project already has a packaging setup,
extend it rather than replacing it.

## Metadata and dependencies

- Use `pyproject.toml` only. Do not add a new `setup.py` or
  `setup.cfg`. If a project still has them, leave them alone unless the
  task is to migrate.
- Runtime dependencies go in `[project] dependencies`. Test
  dependencies go in `[project.optional-dependencies]` under the key
  `test`, so that `pip install -e '.[test]'` gives a working test
  environment.
- Pin lower bounds only where you know a real minimum. Do not add
  upper bounds without a reason you can state in a comment.
- Add a dependency only when the task needs it, and say why in the
  report. Prefer the standard library.

## Environments

- Install into the worktree's own `.venv` with
  `.venv/bin/python -m pip install -e '.[test]'`. Never install into
  the system Python and never use `sudo pip`.
- Do not commit `.venv`, `build/`, `dist/` or `*.egg-info`. Check that
  `.gitignore` covers them.
- Run tools as `.venv/bin/python -m <tool>` so the right interpreter is
  used.

## PyInstaller

- A `.spec` file is specific to the platform it was built on: paths,
  hidden imports and binaries differ between Linux, macOS and Windows.
- A change to a spec file, or to code that changes what it must bundle,
  cannot be verified on this host alone. It needs the platform's own CI
  to build it. Say so in the report and do not claim it works.
- Do not edit a spec for one platform to fix another.
