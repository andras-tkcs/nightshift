# Using Nightshift

You queue work for Nightshift with the `ns` command on the server, then review what it produced at the review desk the next morning. This page lists the commands, the gates that stop work from going further, and where to look.

## The ns command

Exit codes: 0 ok, 1 failure, 2 usage error; every command has --help.

### ns help

```
ns help
```

`ns help` lists every command with a one-line summary. Running `ns` with no arguments does the same.

Example:

```
$ ns help
usage: ns <command> [args]

commands:
  help       list commands
```

### ns profile check

```
ns profile check [path] [--repo <dir>]
```

`ns profile check` validates a project profile (`path` is a repo directory or a profile file, default `.`) and prints `ok: <file>`, or one line per problem and exit code 1. Problems are: invalid YAML, schema errors, a missing docs file, domain skill or workflow, an unknown stack, and a specialist or risk-zone agent that is not available. `--repo` names the repository the referenced files are looked up in. The keys are listed in [profile-reference.md](profile-reference.md).

### ns profile show

```
ns profile show [path]
```

`ns profile show` prints the resolved profile as JSON: defaults applied, stacks as objects, and the `checks` (lint and test per stack) that will run. See [profile-reference.md](profile-reference.md) for every key.

### ns project add

```
ns project add <owner/repo> --prefix <p> [--sandbox] [--branch <b>]
```

`ns project add` registers a project in `~/.config/ns/projects.yaml`. The prefix is 1 to 10 lowercase letters or digits, starting with a letter, and is unique per project. If `~/Coding/<repo>` already exists and its `origin` is `owner/repo`, it is adopted as the main checkout: nothing in it is cloned, checked out, pulled or changed, and only `git fetch origin` runs. If it exists with another origin the command stops with an error; if it is absent the repo is cloned with `gh`. The token file `~/.config/ns/tokens/<owner>` (mode 600) is used when it exists.

The profile is read from the base branch (or from `--branch`) and checked in a temporary worktree; an invalid profile registers nothing. The stacks' setup runs there once, then the worktree is removed, the desk folder `/srv/ns-space/<repo>/runs` is created and the project is registered. If the base branch has no `.claude/project-profile.yaml`, the command prints how to start the onboarding run `<prefix>-onboard`. `--sandbox` marks the project as an end-to-end test target; `--branch` stores the ref the profile and base branch are read from.

Running it again with the same repo and prefix prints `already registered` and exits 0. A different prefix for a registered repo, or a prefix used by another repo, exits 1.

## Commands inside Claude Code

## Tiers and gates

## The review desk
