#!/usr/bin/env bash
# Automated gate that runs before any model review: static rules on the task diff,
# then the project's test/typecheck/lint command.
#
# Usage: check.sh --task T01 [--repo DIR] [--cmd "npm test"] [--static-only] [--force] [--quiet]
#
#   --task         Task id already delegated with delegate-dev.sh (its baseline must exist).
#   --repo         Any path inside the target git repo (default: current directory).
#   --cmd          Test command. Default: ORCH_CHECK_CMD, else the "Test commands:" line
#                  of .orchestrator/plan.md. Without one, only the static rules run.
#   --static-only  Skip the test command.
#   --force        Re-run even when the tree is unchanged since the last passing check.
#   --quiet        Print only the result line and the report path.
#
# Static findings are reported without running the test command: fix them first, then the
# tests run once. A tree unchanged since the last PASS reuses that result.
# Static rules look only at lines the task added. Silence a deliberate exception by
# putting "orch-allow" in a comment on that line.
# Writes .orchestrator/checks/<task>-c<N>.md and records the result in <task>.last.
# Exit codes: 0 pass, 4 checks failed, other non-zero means the script itself failed.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

task="" repo="." test_cmd="" cmd_set=0 static_only=0 force=0 quiet=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task=${2:?}; shift 2 ;;
    --repo) repo=${2:?}; shift 2 ;;
    --cmd) test_cmd=${2?}; cmd_set=1; shift 2 ;;
    --static-only) static_only=1; shift ;;
    --force) force=1; shift ;;
    --quiet) quiet=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n $task ]] || die "--task is required"
check_task_id "$task"
main="$(main_root "$repo")"
orch="$main/.orchestrator"
work="$(task_workdir "$main" "$task")"
[[ -f "$orch/baselines/$task.tree" ]] || die "no baseline for $task; run delegate-dev.sh --task $task first"
ensure_workspace "$main"
(( cmd_set )) || test_cmd="$(plan_test_cmd "$orch")"

n=1
while [[ -e "$orch/checks/$task-c$n.md" ]]; do n=$((n + 1)); done
report="$orch/checks/$task-c$n.md"
test_log="$orch/logs/$task-check-c$n.log"

base="$(<"$orch/baselines/$task.tree")"

if (( !force && !static_only )) && [[ "$(cat "$orch/checks/$task.last" 2>/dev/null || true)" == "PASS $(worktree_tree "$work")" ]]; then
  {
    echo "## CHECK RESULT: PASS"
    echo
    echo "- Task: $task (check $n)"
    echo "- Tree unchanged since the last passing check; nothing re-run."
  } > "$report"
  if (( quiet )); then echo "CHECK RESULT: PASS ($report, cached)"; else cat "$report"; fi
  exit 0
fi

# --- Static rules ----------------------------------------------------------
findings="$(git -C "$main" diff -U0 --no-color --no-ext-diff "$base" "$(worktree_tree "$work")" | perl -ne '
  BEGIN {
    %msg = (
      "strict-zod"         => q{server input schema uses z.object; use z.strictObject so unknown keys (ownerId, role) are rejected},
      "actor-from-request" => q{owner/user/role taken from the request; the actor must come from req.actor (server session)},
      "sql-interpolation"  => q{SQL built with ${...} interpolation; use $N parameters},
      "unscoped-query"     => q{query by id without owner_id/user_id in the same WHERE clause (IDOR)},
      "route-without-mfa"  => q{API router mounted without requireMfa},
      "focused-or-skipped" => q{focused or skipped test (.only/.skip) left in},
      "type-suppression"   => q{type checking silenced (@ts-ignore, @ts-nocheck or any)},
      "raw-html"           => q{dangerouslySetInnerHTML},
      "client-secret"      => q{secret-looking VITE_* variable; anything VITE_* ships to the browser},
      "missing-idor-test"  => q{new routes file but no added test mentions IDOR / cross-user},
    );
  }
  sub hit { my ($rule, $text) = @_; $text =~ s/^\s+|\s+$//g; $text = substr($text, 0, 160);
            print "$rule\t$file\t$ln\t$text\t$msg{$rule}\n"; }
  if (/^\+\+\+ (?:b\/)?(.*)$/) { $file = $1; $new{$file} = 1 if $prev_null; $prev_null = 0; next; }
  if (/^--- (.*)$/) { $prev_null = ($1 eq "/dev/null"); next; }
  if (/^@@ -\S+ \+(\d+)/) { $ln = $1 - 1; next; }
  next unless /^\+/;
  $ln++;
  my $l = substr($_, 1); chomp $l;
  next if $file =~ m{(^|/)(node_modules|dist|build|\.orchestrator)/};
  $idor_test = 1 if $file =~ /\.(test|spec)\.[cm]?[jt]sx?$/ && $l =~ /idor|cross-user/i;
  next unless $file =~ /\.[cm]?[jt]sx?$/;
  next if $l =~ /orch-allow/;
  my $client = $file =~ m{(^|/)(web|client|frontend|ui)/} || $file =~ /\.tsx$/;
  my $test = $file =~ /\.(test|spec)\.[cm]?[jt]sx?$/ || $file =~ m{(^|/)tests?/};
  $routes{$file} = 1 if $new{$file} && $file =~ /\.routes?\.[cm]?[jt]s$/;
  hit("strict-zod", $l) if !$client && !$test && $l =~ /\bz\.object\(/;
  hit("actor-from-request", $l) if $l =~ /req\.(body|query|params)\??\.(ownerId|owner_id|userId|user_id|role|isAdmin)\b/
                                || $l =~ /\{[^}]*\b(ownerId|owner_id|userId|user_id|role)\b[^}]*\}\s*=\s*req\.(body|query|params)\b/;
  if ($l =~ /\b(SELECT|INSERT|UPDATE|DELETE)\b.*\$\{/ && !$test) {
    (my $rest = $l) =~ s/\$\{[A-Z0-9_]+\}//g;     # ${COLUMNS}-style constants are fine
    hit("sql-interpolation", $l) if $rest =~ /\$\{/;
  }
  hit("unscoped-query", $l) if $file =~ /repositor/i && $file !~ /(user|session|mfa|auth|otp|totp)/i
                            && $l =~ /\bWHERE\b.*\bid\s*=\s*\$\d/i && $l !~ /\b(owner_id|user_id)\b/;
  hit("route-without-mfa", $l) if $l =~ /\.use\(\s*[\x27"`]\/api\/(?!auth\b)[^\x27"`]+[\x27"`]/ && $l !~ /requireMfa/;
  hit("focused-or-skipped", $l) if $l =~ /\b(it|test|describe)\.(only|skip)\(|\b[fx](it|describe)\(/;
  hit("type-suppression", $l) if $l =~ /\@ts-(ignore|nocheck)\b|\bas any\b|:\s*any\b|<any>/;
  hit("raw-html", $l) if $l =~ /dangerouslySetInnerHTML/;
  hit("client-secret", $l) if $l =~ /\bVITE_\w*(SECRET|PRIVATE|PASSWORD|PEPPER|TOKEN|API_KEY)/;
  END {
    unless ($idor_test) { for my $f (sort keys %routes) { $file = $f; $ln = 1; hit("missing-idor-test", "(new file)"); } }
  }
')"

static_count=0
[[ -n $findings ]] && static_count="$(printf '%s\n' "$findings" | wc -l | tr -d ' ')"

# --- Test command ----------------------------------------------------------
test_status=skipped
if (( static_count > 0 && !static_only )) && [[ -n $test_cmd ]]; then
  test_status="not run (fix the static findings first)"
elif (( !static_only )) && [[ -n $test_cmd ]]; then
  (( quiet )) || echo "Running checks for $task: $test_cmd" >&2
  set +e
  (cd "$work" && CI=1 bash -c "$test_cmd") > "$test_log" 2>&1
  rc=$?
  set -e
  strip_ansi < "$test_log" > "$test_log.tmp" && mv "$test_log.tmp" "$test_log"
  if (( rc == 0 )); then test_status=pass; else test_status="fail (exit $rc)"; fi
fi

result=PASS
(( static_count > 0 )) && result=FAIL
[[ $test_status == fail* ]] && result=FAIL

{
  echo "## CHECK RESULT: $result"
  echo
  echo "- Task: $task (check $n)"
  echo "- Static rules: $static_count finding(s)"
  echo "- Test command: ${test_cmd:-none configured} -> $test_status"
  if (( static_count > 0 )); then
    echo
    echo "### Static findings"
    printf '%s\n' "$findings" | awk -F'\t' '{ printf "- [%s] %s:%s - %s\n  `%s`\n", $1, $2, $3, $5, $4 }'
    echo
    echo "Fix each finding, or, if it is a deliberate and safe exception, add an \"orch-allow: <reason>\" comment on that line."
  fi
  if [[ $test_status == fail* ]]; then
    echo
    echo "### Test output (last 80 lines; full log: $test_log)"
    echo '```'
    tail -n 80 "$test_log"
    echo '```'
  fi
} > "$report"

(( static_only )) || echo "$result $(worktree_tree "$work")" > "$orch/checks/$task.last"

if (( quiet )); then
  echo "CHECK RESULT: $result ($report)"
else
  cat "$report"
  echo
  echo "report: $report"
fi
[[ $result == PASS ]] || exit 4
