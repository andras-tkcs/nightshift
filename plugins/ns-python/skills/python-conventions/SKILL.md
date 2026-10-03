---
name: python-conventions
description: Use when editing Python files, to follow the style conventions Nightshift expects unless the project says otherwise.
user-invocable: false
---

# Python conventions

Apply these when you write or change Python code. They are defaults.
The project's own guidelines (CLAUDE.md, CONTRIBUTING, ruff or
pyproject settings, the style of the surrounding code) always win. If
they conflict with this file, follow the project.

## Rules

- Put type hints on every public function and method: parameters and
  return type. Private helpers may skip them when obvious.
- Use `pathlib.Path` for file system paths, not string concatenation or
  `os.path` joins.
- Never use a bare `except:`. Catch the narrowest exception that you can
  handle, and let the rest propagate. Do not swallow errors silently.
- Use f-strings for formatting. Use lazy `%s` arguments only in
  `logging` calls.
- Keep functions small and single-purpose. If a function needs a comment
  to separate its sections, split it.
- Prefer plain data (dataclasses, dicts, tuples) over clever class
  hierarchies.
- No mutable default arguments. Use `None` and create the value inside.
- Use context managers (`with`) for files, locks and connections.
- Imports at the top of the file, grouped standard library, third party,
  local. Let ruff sort them.

## Before you finish

1. Run the project's lint command (for example `ruff check .`) and fix
   what it reports. Do not silence a rule with `noqa` unless the project
   already does so for the same case.
2. Run the type checker if the project has one configured.
3. Match the existing naming and layout. Do not reformat code you did
   not change.

## What not to do

- Do not add new dependencies for something the standard library does.
- Do not rewrite working code to match these rules in a change that is
  about something else. Mention it in the report instead.
