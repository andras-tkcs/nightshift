# Adding a project

How to bring a repository under Nightshift. The first project is the one you register first; every later one follows the same steps. Run these on `ns-main` as user `ns` unless a step says root. Why projects are separate clones is in [architecture.md](architecture.md), "More projects".

## Before you start

- Nightshift is installed ([setup.md](setup.md)) and `ns doctor` is green.
- The repo exists on GitHub. If you have a local clone at `~/Coding/<repo>` with the right `origin`, `ns project add` adopts it.

## 1. Give the agents a token

Agents use a fine-grained GitHub token, one per owner (your account, an organisation). Save it in `~/.config/ns/tokens/<owner>` with mode 600, and add the new repo to that token's repository list in GitHub. `ns project add` uses the file when it exists.

```
mkdir -p ~/.config/ns/tokens
read -rsp "token: " T; printf '%s\n' "$T" > ~/.config/ns/tokens/<owner>; unset T; echo
chmod 600 ~/.config/ns/tokens/<owner>
```

## 2. Register the project

```
ns project add <owner/repo> --prefix <p>
```

The prefix names the project's runs (`app-7`). The command:

- adopts `~/Coding/<repo>` when its `origin` is `owner/repo`: it only runs `git fetch origin` and never works in, checks out or changes that main checkout. If the folder has another origin it stops; if it is absent it clones.
- checks the profile on the base branch in a temporary worktree, runs the stack setup there once and removes it;
- creates the desk folder and adds the project to `~/.config/ns/projects.yaml`;
- starts the onboarding run `<prefix>-onboard` when the base branch has no `.claude/project-profile.yaml`.

Running it again with the same repo and prefix is harmless. `--sandbox` marks an end-to-end test target; `--branch` sets the ref the profile is read from. Details: [usage.md](usage.md).

## 3. The onboarding run

The onboarding run reads the README, CI workflows, docs, ADRs and build files, and drafts the project's files. Rules (R-ONB):

- It only adds files: `.claude/project-profile.yaml`, `.claude/ns-github.env` and at most one domain-skill draft, `.claude/skills/<prefix>-invariants/SKILL.md`. It never edits or deletes an existing file, so `CLAUDE.md` and existing `.claude/commands/` stay as they are.
- Every value it guessed is marked `# guess:` in the draft. Check each one.
- It runs `ns profile check` on the drafts, publishes them to the review desk and waits at a gate.

Watch it with `ns ls` and `ns attach <prefix>-onboard`. When it waits, open the drafts on the desk and edit them: mostly the commands, the risk zones and the definition of done.

## 4. Approve and merge

```
ns approve <prefix>-onboard
```

This commits your edited drafts to the branch `nightshift/onboard`, pushes it and opens a pull request to the base branch. Nightshift never merges it: review and merge it yourself on GitHub.

Until that pull request is merged, `ns new` refuses to start a run for the project and names the open PR.

## 5. GitHub settings, as root

Only after the onboarding PR is merged: `ns-gh` reads `.claude/ns-github.env` from the default branch, so it must exist there first (R-BS-3). As root on `ns-main`, with an admin token for the owner:

```
read -rsp "admin token: " GH_TOKEN; export GH_TOKEN; echo
ns-gh audit <owner/repo>
ns-gh apply <owner/repo>
unset GH_TOKEN
```

`audit` changes nothing; `apply` shows the differences and asks first. The admin token never reaches the agents.

## 6. Smoke test

Start one T0 job, such as a typo or a docs fix:

```
ns new <prefix> "Fix the typo in README" --tier T0
ns ls
```

When it reaches a green pull request, the project is ready for bigger tiers.

## Starter files

A project's files for Nightshift. The onboarding run drafts the ones marked "draft"; the rest you add yourself when you need them.

| File | What it is for | Onboarding |
|---|---|---|
| `CLAUDE.md` | Short: what the project is, where the house docs are, the few rules every session needs. No workflow, that is Nightshift's. | untouched |
| `.claude/project-profile.yaml` | The contract: commands, git conventions, CI workflows, risk zones, domain skills. | draft |
| `.claude/settings.json` | Permission rules only, for example deny reading `.env*` and force pushes. The plugins are installed per user, so the project never references them. | not touched |
| `.claude/skills/<prefix>-invariants/SKILL.md` | The project's non-negotiables, used as review criteria. Add more domain skills as reviews keep catching the same things. | draft |
| `.claude/ns-github.env` | Per-project overrides for `ns-gh`. | draft |
| `docs/coding-and-testing-guidelines.md` | Conventions and a numbered definition-of-done section that `/ns:dod` runs. | not touched |
| `docs/adr/0001-record-architecture-decisions.md` | Starts the ADR log the architect writes into. | not touched |
| `CONTRIBUTING.md` | Branch and PR rules for humans; the profile points to it. | not touched |
| `.github/workflows/tests.yml` | The CI gate whose check name goes into `REQUIRED_CHECKS`. | not touched |
| `.github/pull_request_template.md` | The definition-of-done checklist and a manual-after section. | not touched |
| `.github/ISSUE_TEMPLATE/nightshift.yml` | A request form: goal, acceptance criteria, suggested tier, out of scope. | not touched |
| `.gitignore` additions | `.claude/worktrees/`, `.claude/settings.local.json`, plus the stack's own (`.venv/` for Python). | not touched |

Every profile key is in [profile-reference.md](profile-reference.md).

## .claude/ns-github.env

Overrides for `ns-gh`, read from the default branch as data and never executed. Only keys that differ from `ns-gh`'s defaults are needed; the onboarding run writes at least `REQUIRED_CHECKS` when the repo has CI jobs.

```
REQUIRED_CHECKS="pytest"
ENVIRONMENTS="live-qa:reviewer"
```

`REQUIRED_CHECKS` is a comma-separated list of status check names that must pass before merging. `ENVIRONMENTS` is a comma-separated list of `name:mode`, where mode is `reviewer` or `main-only`. Other keys: `DEFAULT_BRANCH`, `ALLOW_MERGE_COMMIT`, `ALLOW_SQUASH_MERGE`, `ALLOW_REBASE_MERGE`, `DELETE_BRANCH_ON_MERGE`, `WORKFLOW_PERMISSIONS`, `ARTIFACT_RETENTION_DAYS`, `LABELS`.

## Build B

- `/ns:init` scaffolds the starter files into an empty repo: Build B.
- `/ns:onboard` researches an existing repo from inside Claude Code and drafts the starter files: Build B. In Build A the onboarding run described above does the draft work.
