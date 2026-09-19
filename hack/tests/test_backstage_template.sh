#!/usr/bin/env bash
# Backstage software template "helm-chart-repo" (#25): render the skeleton locally the way the scaffolder would,
# then lint the result like its own CI does (helm lint/template, yamllint). Needs node + npm (nunjucks from the npm
# registry), yamllint, and network for helm (the umbrella case pulls podinfo from ghcr.io).
# BACKSTAGE_TEMPLATE_PRECOMMIT=1 also runs the rendered repo's `pre-commit run --all-files` (slow: fetches hook repos).
source "$(dirname "$0")/lib.sh"
t=repos/platform-config/backstage/templates/helm-chart-repo
# skipped locally without its tools (like test_argocd_pvc_health.sh); CI (CI=true) must run it
for c in node npm yamllint; do
  command -v $c >/dev/null && continue
  [ -z "${CI:-}" ] || fail "need $c (node/npm render the template with nunjucks like Backstage; yamllint lints it)"
  echo "skip: $c not on PATH (test_backstage_template.sh needs node, npm and yamllint)"; exit 0
done
# nunjucks is the scaffolder's template engine (scaffolder-backend 4.0.0 depends on ^3.2.3); cached like helm's deps
nj="${XDG_CACHE_HOME:-$HOME/.cache}/platform-lab/nunjucks"
[ -d "$nj/node_modules/nunjucks" ] || npm install --silent --no-save --prefix "$nj" nunjucks@3.2.4 >/dev/null ||
  fail "npm install nunjucks"

# scaffold <name> <parameters as YAML> -> dir with workspace/ (fetch:template output), steps.yaml, output.yaml
scaffold() {
  local out
  out=$(mktemp -d "$tmp/$1.XXXXXX")
  yq -o=json "$t/template.yaml" > "$out/template.json" || fail "yq $t/template.yaml"
  yq -o=json <<<"$2" > "$out/params.json" || fail "yq params"
  NODE_PATH="$nj/node_modules" node hack/tests/backstage-render.js "$out/template.json" "$t" "$out/params.json" "$out" ||
    fail "render $1"
  echo "$out"
}
# lint_repo <workspace>: what the generated repo's CI lint/test stages check, minus network-only kubeconform
lint_repo() {
  ! grep -rn '\${{\|{%\|{#' "$1" || fail "$1: unrendered nunjucks left"
  yamllint --strict -c "$1/.yamllint" "$1" || fail "$1: yamllint"
  grep -q '^dependencies:' "$1/Chart.yaml" && { helm dependency update "$1" >/dev/null || fail "helm dependency update $1"; }
  helm lint --strict "$1" >/dev/null || fail "helm lint --strict $1"
  helm template ci "$1" > "$1.rendered.yaml" || fail "helm template $1"
}

# --- template.yaml: scaffolder v1beta3, steps fetch:template -> publish:gitlab|github -> catalog:register
assert_yq $t/template.yaml '.apiVersion' scaffolder.backstage.io/v1beta3
assert_yq $t/template.yaml '.kind' Template
assert_yq $t/template.yaml '.metadata.name' helm-chart-repo
assert_yq $t/template.yaml '[.spec.steps[].action] | join(",")' \
  'fetch:template,publish:gitlab,publish:github,catalog:register,catalog:register'
assert_yq $t/template.yaml '.spec.steps[0].input.url' ./skeleton
# credentials never pass through the template: only the (non-secret) repo URL becomes a project variable
assert_yq $t/template.yaml '[.spec.steps[] | select(.action=="publish:gitlab") | .input.projectVariables[].key] | join(",")' \
  ARTIFACTORY_URL
! grep -rnE '^[[:space:]]*(ARTIFACTORY_(USER|TOKEN|PASSWORD)[A-Z_]*|RELEASE_TOKEN):[[:space:]]+[^[:space:]]' $t ||
  fail "Artifactory credentials / RELEASE_TOKEN must not be set in the template or skeleton"

# --- plain chart, GitLab (the intended target)
g=$(scaffold plain-gitlab '
name: payments-chart
description: "Payments: Helm chart"
owner: group:default/team-payments
chartType: plain
publishTarget: gitlab
gitlabHost: gitlab.example.com
gitlabGroup: platform/helm-charts
visibility: internal
artifactoryUrl: oci://artifactory.example.com/helm-local')
w=$g/workspace
assert_yq $g/steps.yaml '[.[] | select(.skipped == false) | .action] | join(",")' 'fetch:template,publish:gitlab,catalog:register'
assert_yq $g/steps.yaml '.[] | select(.id=="publish-gitlab") | .input.repoUrl' \
  'gitlab.example.com?owner=platform/helm-charts&repo=payments-chart'
assert_yq $g/steps.yaml '.[] | select(.id=="publish-gitlab") | .input.defaultBranch' main
assert_yq $g/steps.yaml '.[] | select(.id=="publish-gitlab") | .input.settings.visibility' internal
assert_yq $g/steps.yaml '.[] | select(.id=="publish-gitlab") | .input.projectVariables[0].value' \
  oci://artifactory.example.com/helm-local
# the initial commit is a conventional `feat`, so the first release is 0.0.0 -> 0.1.0 (once RELEASE_TOKEN is set and
# the first pipeline's release job is retried: publish:gitlab pushes before it creates variables)
assert_yq $g/steps.yaml '.[] | select(.id=="publish-gitlab") | .input.gitCommitMessage | test("^feat: ")' true
assert_yq $g/steps.yaml '.[] | select(.id=="register-gitlab") | .input.repoContentsUrl' \
  'https://gitlab.example.com/platform/helm-charts/payments-chart/-/blob/main'
assert_yq $g/steps.yaml '.[] | select(.id=="register-gitlab") | .input.catalogInfoPath' /catalog-info.yaml
assert_yq $g/output.yaml '[.links[].title] | join(",")' 'Repository,Open in catalog'
assert_yq $w/Chart.yaml '.name' payments-chart
assert_yq $w/Chart.yaml '.description' 'Payments: Helm chart'
assert_yq $w/Chart.yaml '.version' 0.0.0
assert_yq $w/Chart.yaml '.dependencies' null
assert_yq $w/.cz.toml '.tool.commitizen.version' 0.0.0
assert_yq $w/.cz.toml '.tool.commitizen.version_files | join(",")' 'Chart.yaml:^version'
assert_yq $w/catalog-info.yaml '.metadata.name' payments-chart
assert_yq $w/catalog-info.yaml '.spec.owner' group:default/team-payments
assert_yq $w/catalog-info.yaml '.metadata.annotations["gitlab.com/project-slug"]' platform/helm-charts/payments-chart
grep -qx '\* @platform/helm-charts' $w/CODEOWNERS || fail "CODEOWNERS: want '* @platform/helm-charts'"
[ -f $w/templates/deployment.yaml ] || fail "plain chart: templates/ missing"
# the generated pipeline: stages, release only from main, publish only from semver tags, no creds in the file
ci=$w/.gitlab-ci.yml
assert_yq $ci '.stages | join(",")' lint,test,release,publish
assert_yq $ci '.variables.ARTIFACTORY_URL' null
assert_yq $ci '.variables.ARTIFACTORY_TOKEN' null
assert_yq $ci '[.lint.script[] | select(test("pre-commit run --all-files"))] | length' 1
assert_yq $ci '[.release.rules[].if | select(test("CI_DEFAULT_BRANCH"))] | length' 1
assert_yq $ci '[.publish.rules[].if | select(test("CI_COMMIT_TAG"))] | length' 1
assert_yq $w/.pre-commit-config.yaml '.default_install_hook_types | join(",")' pre-commit,commit-msg
assert_yq $w/.pre-commit-config.yaml '[.repos[].hooks[].id] | contains(["helm-lint","helm-template","yamllint","conventional-pre-commit","end-of-file-fixer"])' true
lint_repo $w
assert_yq $w.rendered.yaml '[select(.kind=="Deployment") | .metadata.name] | join(",")' ci-payments-chart

# --- umbrella chart: upstream as the only dependency, values nested under its name, no own objects
u=$(scaffold umbrella-gitlab '
name: podinfo-umbrella
description: podinfo wrapped for the platform
owner: group:default/platform
chartType: umbrella
upstreamChart: podinfo
upstreamRepository: oci://ghcr.io/stefanprodan/charts
upstreamVersion: 6.15.0
publishTarget: gitlab
gitlabHost: gitlab.example.com
gitlabGroup: platform
visibility: private
artifactoryUrl: https://artifactory.example.com/artifactory/helm-local')
w=$u/workspace
assert_yq $w/Chart.yaml '.dependencies[0].name' podinfo
assert_yq $w/Chart.yaml '.dependencies[0].version' 6.15.0
assert_yq $w/Chart.yaml '.dependencies[0].repository' oci://ghcr.io/stefanprodan/charts
assert_yq $w/Chart.yaml '.appVersion' 6.15.0
assert_yq $w/values.yaml 'has("podinfo")' true
[ "$(ls $w/templates)" = NOTES.txt ] || fail "umbrella chart: templates/ must hold only NOTES.txt, got: $(ls $w/templates)"
lint_repo $w
assert_yq $w.rendered.yaml '[select(.kind=="Deployment") | .metadata.name] | join(",")' ci-podinfo

# --- GitHub fallback: OpenChoreo 1.2.5's Backstage bundles publish:github but not publish:gitlab
h=$(scaffold plain-github '
name: lab-chart
description: throwaway chart to prove the template in the lab
owner: group:default/openchoreo-users
chartType: plain
publishTarget: github
githubOwner: koorikla')
bundled='fetch:template,publish:github,catalog:register'
# the Artifactory URL is asked only for GitLab (publish:gitlab stores it as a CI/CD variable; GitHub would drop it)
assert_yq $t/template.yaml '[.spec.parameters[].required[]] | contains(["artifactoryUrl"])' false
assert_yq $t/template.yaml '.spec.parameters[1].dependencies.publishTarget.oneOf[] | select(.properties.publishTarget.enum[0]=="gitlab") | .required | contains(["artifactoryUrl"])' true
assert_yq $t/template.yaml '.spec.parameters[1].dependencies.publishTarget.oneOf[] | select(.properties.publishTarget.enum[0]=="github") | .properties | has("artifactoryUrl")' false
assert_yq $h/steps.yaml '[.[] | select(.skipped == false) | .action] | join(",")' "$bundled"
assert_yq $h/steps.yaml '.[] | select(.id=="publish-github") | .input.repoUrl' 'github.com?owner=koorikla&repo=lab-chart'
assert_yq $h/steps.yaml '.[] | select(.id=="register-github") | .input.repoContentsUrl' \
  'https://github.com/koorikla/lab-chart/blob/main'
assert_yq $h/workspace/catalog-info.yaml '.metadata.annotations["github.com/project-slug"]' koorikla/lab-chart
assert_yq $h/workspace/catalog-info.yaml '.metadata.annotations["gitlab.com/project-slug"]' null
lint_repo $h/workspace

if [ "${BACKSTAGE_TEMPLATE_PRECOMMIT:-0}" = 1 ]; then
  command -v pre-commit >/dev/null || fail "need pre-commit"
  for r in $g/workspace $u/workspace; do
    rm -rf "$r/charts" "$r/Chart.lock"   # fresh clone state
    git -C "$r" init -q -b main && git -C "$r" add -A
    (cd "$r" && pre-commit run --all-files) || fail "$r: pre-commit run --all-files"
  done
fi
