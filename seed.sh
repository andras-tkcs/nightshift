#!/usr/bin/env bash
# seed.sh: copy the PrivacyFence dev tooling into this repo as the starting point for Build A.
# Run once, as ns, from the root of the nightshift checkout. Safe to rerun.
set -euo pipefail

[[ -f docs/spec.md && -f docs/build-plan.md ]] || { echo "run from the nightshift repo root, after committing docs/spec.md and docs/build-plan.md" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git clone --quiet --depth 1 https://github.com/privacyfence/privacyfence "$tmp/pf"

mkdir -p .claude/commands seed/steward
# dev tooling that runs here as-is
cp "$tmp/pf/.claude/commands/make-plan.md" .claude/commands/make-plan.md
# source material for porting into the plugin (not run from here)
cp "$tmp/pf/.claude/commands/implement.md" seed/implement.md
cp "$tmp/pf/.claude/commands/dod.md"       seed/dod.md
cp -r "$tmp/pf/.claude/skills/steward/."   seed/steward/
cp "$tmp/pf/docs/coding-and-testing-guidelines.md" seed/pf-coding-and-testing-guidelines.md

cat > seed/README.md <<'EOF'
Copied from privacyfence/privacyfence as source material for Build A.
Port their logic into plugins/ns (spec §6–§9); turn every PrivacyFence-specific fact into a profile key.
Nothing in this folder is executed. Delete it in Build A's last phase.
EOF

echo "copied:"
find .claude/commands seed -type f | sort
echo
echo "next: git add -A && git commit -m 'Seed dev tooling from PrivacyFence' && git push"
