import json

import profile as nsprofile


def test_apply_defaults_fills_missing_nested_keys_only():
    schema = {"properties": {
        "a": {"default": 1},
        "b": {"properties": {"c": {"default": "x"}, "d": {"default": 2}}},
    }}
    out = nsprofile.apply_defaults(schema, {"b": {"d": 9}})
    assert out == {"a": 1, "b": {"c": "x", "d": 9}}


def test_apply_defaults_does_not_share_default_objects():
    schema = {"properties": {"l": {"default": []}}}
    first = nsprofile.apply_defaults(schema, {})
    first["l"].append(1)
    assert nsprofile.apply_defaults(schema, {}) == {"l": []}


def test_apply_defaults_ignores_non_dict():
    assert nsprofile.apply_defaults({"properties": {}}, [1]) == [1]


def test_defaults_command_emits_json_object(capsys):
    assert nsprofile.main(["profile.py", "defaults"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert isinstance(out, dict) and "git" in out


def test_usage(capsys):
    assert nsprofile.main(["profile.py", "bogus"]) == 2
    assert "usage:" in capsys.readouterr().err
