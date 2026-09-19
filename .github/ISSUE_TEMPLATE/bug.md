---
name: Bug
about: Something on the lab or in a render does not behave as the repo says it should.
title: ""
labels: [bug]
assignees: []
---

<!-- Add area:* labels; add needs-lab if it only reproduces on the live lab. Never paste secret material
(tokens, keys, kubeconfigs, Secret data): redact, or show only key names. -->

## What happened
<!-- Symptom, with the key lines of output (kubectl / argocd / kargo / make). -->

## What should have happened
<!-- Point at the doc, invariant (CLAUDE.md) or test that says so. -->

## Where
- Commit on `main`: <!-- git rev-parse --short origin/main -->
- Cluster(s) / app / addon: <!-- e.g. mgmt, dev1, cert-manager-dev1 -->
- Offline (`make lint` / `make test`) or live lab:

## Reproduce
1.

## Lab state
<!-- Did you hold the lab lock (hack/lab-lock.sh status)? Anything you changed by hand that Argo will revert or that
someone must undo? -->
