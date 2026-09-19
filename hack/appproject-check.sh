#!/usr/bin/env bash
# Would the AppProjects in git admit what Argo CD deploys? Read-only; exits 1 and prints every rejection.
#   hack/appproject-check.sh [--projects FILE] < records    records from renders (hack/tests/test_appprojects.sh)
#   hack/appproject-check.sh --live [--context CTX]         the hub's live Applications (sources, destination,
#                                                            .status.resources) against the projects in git: run it
#                                                            before merging a projects.yaml change
# Record lines (tab-separated; namespace "" = cluster-scoped resource):
#   src <app> <project> <repoURL>
#   dst <app> <project> <cluster> <namespace>                     the Application's own destination
#   res <app> <project> <cluster> <namespace> <group> <kind>      one resource it syncs
# Rules re-implemented from Argo CD v3.5.3 (pkg/apis/application/v1alpha1/app_project_types.go: IsSourcePermitted,
# isDestinationMatched, IsGroupKindNamePermitted; util/git NormalizeGitURL) and, for projects labelled
# argocd-agent=true, argocd-agent v0.10.0 (internal/manager/appproject: AgentSpecificAppProject). Those projects are
# enforced twice: on the hub (argocd-server validates the Application against destination.name = the cluster) and on
# the worker, where the agent's Argo CD syncs with the agent-specific copy: only the destinations whose name glob
# matches the agent survive, rewritten to in-cluster (a "!name" deny is a literal there and never survives).
set -euo pipefail
cd "$(dirname "$0")/.."
projects=repos/platform-config/argocd/projects.yaml live=false ctx=mgmt
while [ $# -gt 0 ]; do
  case $1 in
    --projects) projects=$2; shift 2 ;;
    --live) live=true; shift ;;
    --context) ctx=$2; shift 2 ;;
    *) echo "usage: $0 [--projects FILE] [--live [--context CTX]]" >&2; exit 2 ;;
  esac
done

records() {
  if ! $live; then cat; return; fi
  # namespace "" in .status.resources = cluster-scoped; destination by server only (none here today) -> in-cluster.
  # Project default (Argo CD's built-in, only `root` uses it) is not in git: skipped.
  kubectl --context "$ctx" -n argocd get applications -o json | jq -r '.items[] | select(.spec.project != "default") |
    .metadata.name as $a | .spec.project as $p |
    (.spec.destination.name // (if .spec.destination.server == "https://kubernetes.default.svc" then "in-cluster"
      else .spec.destination.server end)) as $c |
    ([.spec.source // empty, (.spec.sources // [])[]] | .[] | ["src", $a, $p, .repoURL]),
    ["dst", $a, $p, $c, (.spec.destination.namespace // "")],
    (.status.resources // [] | .[] | ["res", $a, $p, $c, (.namespace // ""), (.group // ""), .kind]) | @tsv'
}

records | jq -rR --slurpfile projs <(yq -o json '.' "$projects" | jq -s '[.[] | select(.kind == "AppProject")]') '
  def re_escape: gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)");
  # gobwas/glob as Argo CD uses it: * spans anything except the separators, ** everything
  def glob($p; $v; $sep):
    ($p | re_escape | gsub("\\?"; ".") | gsub("\\*\\*"; "%ANY%") | gsub("\\*"; if $sep then "[^/]*" else ".*" end)
      | gsub("%ANY%"; ".*")) as $re | ($v | test("^" + $re + "$"));
  def deny: (. // "") | startswith("!");
  def gm($p; $v; $sep): if ($p | deny) then (glob($p[1:]; $v; $sep) | not) elif $p == "*" then true
                        else glob($p; $v; $sep) end;
  def normurl: ascii_downcase | ltrimstr(" ") | rtrimstr(" ") | rtrimstr(".git");
  def server($c): if $c == "in-cluster" then "https://kubernetes.default.svc"
                  else "https://argocd-agent-resource-proxy:9090?agentName=" + $c end;
  def source_ok($proj; $url):
    reduce ($proj.spec.sourceRepos // [])[] as $r ({any: false, denied: false};
      (if ($r | deny) then "!" + ($r[1:] | normurl) else ($r | normurl) end) as $n
      | if gm($n; $url | normurl; true) then .any = true elif ($n | deny) then .denied = true else . end)
    | .any and (.denied | not);
  def dest_ok($proj; $c; $ns):
    server($c) as $srv
    | reduce ($proj.spec.destinations // [])[] as $i ({any: false, denied: false};
      if .denied then . else
        (gm($i.name // ""; $c; false)) as $nm | (gm($i.server // ""; $srv; false)) as $sm
        | gm($i.namespace // ""; $ns; false) as $nsm
        | if ($sm or $nm) and $nsm then .any = true
          elif ((($nm | not) and ($i.name | deny)) or ((($sm | not) and ($i.server | deny)) and $nsm)) then .denied = true
          elif ($nsm | not) and ($i.namespace | deny) and $sm then .denied = true
          else . end
      end)
    | .any and (.denied | not);
  def kind_ok($proj; $ns; $g; $k):
    def inlist($l): any(($l // [])[]; glob(.kind; $k; false) and glob(.group; $g; false) and ((.name // "") == ""));
    if $ns == "" then inlist($proj.spec.clusterResourceWhitelist) and (inlist($proj.spec.clusterResourceBlacklist) | not)
    else ($proj.spec.namespaceResourceWhitelist == null or inlist($proj.spec.namespaceResourceWhitelist))
      and (inlist($proj.spec.namespaceResourceBlacklist) | not) end;
  # argocd-agent: the copy the worker enforces (destinations matching the agent name, as in-cluster)
  def on_agent($proj; $agent):
    $proj | .spec.destinations = [(.spec.destinations // [])[]
      | select((.name // "") != "" and glob(.name; $agent; false))
      | .name = "in-cluster" | .server = "https://kubernetes.default.svc"];
  def agent_project($proj): ($proj.metadata.labels["argocd-agent"] // "") == "true";

  split("\t") as $r | $r[1] as $app | $r[2] as $pn
  | ($projs[0] | map(select(.metadata.name == $pn)) | first) as $proj
  | if $proj == null then "\($app): project \($pn) is not declared in git"
    elif $r[0] == "src" then
      if source_ok($proj; $r[3]) then empty else "\($app): source \($r[3]) not in \($pn).sourceRepos" end
    elif $r[0] == "dst" then
      (if dest_ok($proj; $r[3]; $r[4]) then empty
       else "\($app): destination \($r[3])/\($r[4]) not permitted by \($pn)" end),
      (if agent_project($proj) and $r[3] != "in-cluster" and (dest_ok(on_agent($proj; $r[3]); "in-cluster"; $r[4]) | not)
       then "\($app): destination \($r[4]) not permitted by \($pn) as the agent \($r[3]) receives it" else empty end)
    elif $r[0] == "res" then
      $r[3] as $c | $r[4] as $ns | $r[5] as $g | $r[6] as $k
      | (if agent_project($proj) and $c != "in-cluster" then on_agent($proj; $c) else $proj end) as $eff
      | (if agent_project($proj) and $c != "in-cluster" then "in-cluster" else $c end) as $ec
      | (if kind_ok($eff; $ns; $g; $k) then empty
         else "\($app): \(if $ns == "" then "cluster-scoped" else "namespaced" end) \($g)/\($k) not whitelisted in \($pn)" end),
        (if $ns == "" or dest_ok($eff; $ec; $ns) then empty
         else "\($app): \($g)/\($k) in namespace \($ns) on \($c) not permitted by \($pn)" end)
    else "bad record: \(.)" end' | sort -u | awk '{print} END {exit NR > 0}'
