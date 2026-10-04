import json

import nsyaml


def test_to_json_converts_yaml(tmp_path, capsys):
    f = tmp_path / "a.yaml"
    f.write_text("name: x\nitems:\n  - 1\n  - two\n")
    assert nsyaml.main(["nsyaml.py", "to-json", str(f)]) == 0
    assert json.loads(capsys.readouterr().out) == {"name": "x", "items": [1, "two"]}


def test_to_json_empty_file_fails(tmp_path, capsys):
    f = tmp_path / "e.yaml"
    f.write_text("  \n")
    assert nsyaml.main(["nsyaml.py", "to-json", str(f)]) == 1
    assert "empty file" in capsys.readouterr().err


def test_from_json_preserves_key_order(tmp_path, monkeypatch):
    import io
    f = tmp_path / "o.yaml"
    monkeypatch.setattr("sys.stdin", io.StringIO('{"z": 1, "a": [true]}'))
    assert nsyaml.main(["nsyaml.py", "from-json", str(f)]) == 0
    assert f.read_text() == "z: 1\na:\n- true\n"
    assert [p.name for p in tmp_path.iterdir()] == ["o.yaml"]


def test_from_json_rejects_bad_json(tmp_path, monkeypatch, capsys):
    import io
    monkeypatch.setattr("sys.stdin", io.StringIO("{nope"))
    assert nsyaml.main(["nsyaml.py", "from-json", str(tmp_path / "x.yaml")]) == 1
    assert "invalid JSON" in capsys.readouterr().err


def test_validate_reports_paths(tmp_path, capsys):
    schema = tmp_path / "s.json"
    schema.write_text(json.dumps({
        "type": "object", "required": ["n"],
        "properties": {"n": {"type": "integer"}}}))
    ok = tmp_path / "ok.yaml"
    ok.write_text("n: 1\n")
    bad = tmp_path / "bad.yaml"
    bad.write_text("n: text\n")
    assert nsyaml.main(["nsyaml.py", "validate", str(ok), str(schema)]) == 0
    assert nsyaml.main(["nsyaml.py", "validate", str(bad), str(schema)]) == 1
    assert f"{bad}: $.n: 'text' is not of type 'integer'" in capsys.readouterr().out


def test_usage_errors(capsys):
    assert nsyaml.main(["nsyaml.py"]) == 2
    assert nsyaml.main(["nsyaml.py", "--help"]) == 0
    assert nsyaml.json_path(["a", 0, "b"]) == "$.a[0].b"
