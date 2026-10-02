# Two phase plan

A short fixture plan for the conductor tests.

## 1. Summary

Add two small files.

## 7. Implementation manifest

```yaml
plan_slug: two-phase
feature_branch: feature/two-phase
max_parallel: 2
phases:
  - id: p1-alpha
    title: Add alpha
    depends_on: []
    complexity: S
    touches: [alpha.txt]
    brief: "1. Create alpha.txt containing the word alpha."
    acceptance: ["test -f alpha.txt"]
  - id: p2-beta
    title: Add beta
    depends_on: []
    complexity: S
    touches: [beta.txt]
    brief: "1. Create beta.txt containing the word beta."
    acceptance: ["test -f beta.txt"]
```
