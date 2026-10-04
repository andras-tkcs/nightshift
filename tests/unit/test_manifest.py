import json

import pytest

import manifest

PLAN = """# Plan

## Implementation manifest

```yaml
phases:
  - id: p1
    title: first
  - id: p2
    title: second
```

## Later
"""


def write(tmp_path, text):
    f = tmp_path / "plan.md"
    f.write_text(text)
    return str(f)


def test_load_manifest_returns_phases(tmp_path):
    phases = manifest.load_manifest(write(tmp_path, PLAN))
    assert [p["id"] for p in phases] == ["p1", "p2"]


def test_missing_heading(tmp_path):
    with pytest.raises(ValueError, match="no Implementation manifest heading"):
        manifest.load_manifest(write(tmp_path, "# Plan\n"))


def test_missing_yaml_block_before_next_heading(tmp_path):
    text = "## Implementation manifest\n\n## Other\n```yaml\nphases: []\n```\n"
    with pytest.raises(ValueError, match="no yaml block"):
        manifest.load_manifest(write(tmp_path, text))


def test_no_phases_list(tmp_path):
    text = "## Implementation manifest\n```yaml\nfoo: 1\n```\n"
    with pytest.raises(ValueError, match="no phases list"):
        manifest.load_manifest(write(tmp_path, text))


def test_main_phase_lookup(tmp_path, capsys):
    path = write(tmp_path, PLAN)
    assert manifest.main(["m", "phase", path, "p2"]) == 0
    assert json.loads(capsys.readouterr().out) == {"id": "p2", "title": "second"}
    assert manifest.main(["m", "phase", path, "zz"]) == 1
    assert "phase not found: zz" in capsys.readouterr().err


def test_main_phases_and_usage(tmp_path, capsys):
    path = write(tmp_path, PLAN)
    assert manifest.main(["m", "phases", path]) == 0
    assert len(json.loads(capsys.readouterr().out)) == 2
    assert manifest.main(["m"]) == 2
