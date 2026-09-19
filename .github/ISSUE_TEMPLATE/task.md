---
name: Task
about: A unit of backlog work (one PR). The coordinator sets status/phase/area labels.
title: ""
labels: []
assignees: []
---

<!-- Labels (coordinator keeps them true):
  status:ready | status:blocked | status:in-progress   exactly one
  phase:<n>                                             plan phase (docs/plans/*-plan.md)
  area:argocd|kargo|capi|openbao|openchoreo|ci|docs|backstage|security|networking   one or more
  needs-lab                                             acceptance needs the shared live lab (verify under hack/lab-lock.sh) -->

## Goal
<!-- What should be true when this is done, in one or two sentences. Plan task number if there is one (e.g. Task 1.5). -->

## Scope
<!-- Paths expected to change. Keep disjoint from other in-flight issues where possible (parallel workers). -->
-

## Acceptance
<!-- Offline: which tests prove it (chart helm-unittest suites, hack/tests). needs-lab: which live checks, and their expected output. -->
- [ ] `make lint && make test` green, with a new/extended helm-unittest suite (chart behaviour) or `hack/tests/test_*.sh` (integration, scripts)
- [ ]

## Out of scope
-

---
Refs: <!-- docs/plans/... section, upstream docs at the pinned version -->
Work it with the `platform-lab-issue` skill (`.claude/skills/`) and CONTRIBUTING.md.

Blocked by: <!-- #n, or delete this line; while any is open the issue stays status:blocked -->
