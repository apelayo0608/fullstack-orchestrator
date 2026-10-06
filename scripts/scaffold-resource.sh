#!/usr/bin/env bash
# Generate a complete owner-scoped CRUD slice for a new resource from the notes
# templates: domain entity + repository port, use cases, Postgres repository with
# field encryption, strict zod routes, IDOR test suite, SQL migration, and
# TanStack Query hooks. The developer then adapts fields and wires it up.
#
# Usage: scaffold-resource.sh --name invoice [--plural invoices] [--api apps/api] [--web apps/web]
#                             [--repo DIR] [--force] [--dry-run]
#
#   --name     Singular name, kebab-case (e.g. invoice, bank-account).
#   --plural   Plural, kebab-case (default: English rules on --name).
#   --api      API package root inside the repo (default: apps/api).
#   --web      Web package root inside the repo (default: apps/web; "none" skips the hooks).
#   --repo     Any path inside the target repo (default: current directory).
#   --force    Overwrite files that already exist.
#   --dry-run  List the files that would be written.
#
# The generated slice keeps the template's example fields (title, encrypted body).
# Replace them with the real fields everywhere they appear, including the IDOR test.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

name="" plural="" api="apps/api" web="apps/web" repo="." force=0 dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) name=${2:?}; shift 2 ;;
    --plural) plural=${2:?}; shift 2 ;;
    --api) api=${2:?}; shift 2 ;;
    --web) web=${2:?}; shift 2 ;;
    --repo) repo=${2:?}; shift 2 ;;
    --force) force=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

kebab_re='^[a-z][a-z0-9]*(-[a-z0-9]+)*$'
[[ $name =~ $kebab_re ]] || die "--name must be kebab-case, e.g. invoice or bank-account (got '$name')"
if [[ -z $plural ]]; then
  case "$name" in
    *[^aeiou]y) plural="${name%y}ies" ;;
    *s|*x|*z|*ch|*sh) plural="${name}es" ;;
    *) plural="${name}s" ;;
  esac
fi
[[ $plural =~ $kebab_re ]] || die "--plural must be kebab-case (got '$plural')"
[[ $plural != "$name" ]] || die "--plural must differ from --name"

root="$(repo_root "$repo")"
tpl="$SKILL_DIR/templates"

pascal() { perl -pe 's/(^|-)([a-z0-9])/\U$2/g' <<<"$1"; }
camel()  { perl -pe 's/-([a-z0-9])/\U$1/g' <<<"$1"; }
snake()  { tr - _ <<<"$1"; }
export S_PASCAL="$(pascal "$name")" S_CAMEL="$(camel "$name")" S_KEBAB="$name"
export P_PASCAL="$(pascal "$plural")" P_CAMEL="$(camel "$plural")" P_KEBAB="$plural" P_SNAKE="$(snake "$plural")"

# Order matters: identifiers first, then SQL/table names (snake), then paths and
# URLs (kebab), then whatever is left (camel).
rename() {
  perl -pe '
    s/Notes/$ENV{P_PASCAL}/g;
    s/Note/$ENV{S_PASCAL}/g;
    s/\b(FROM|INTO|UPDATE|TABLE|ON) notes\b/$1 $ENV{P_SNAKE}/g;
    s/AAD: notes\b/AAD: $ENV{P_SNAKE}/g;
    s/\bnotes(?=\.routes)/$ENV{P_KEBAB}/g;
    s/\x27notes\x27/\x27$ENV{P_SNAKE}\x27/g;
    s/\bnotes_/$ENV{P_SNAKE}_/g;
    s{/notes\b}{/$ENV{P_KEBAB}}g;
    s{/note\b}{/$ENV{S_KEBAB}}g;
    s/\bnotes/$ENV{P_CAMEL}/g;
    s/\bnote/$ENV{S_CAMEL}/g;
  '
}

mig_dir="$root/$api/db/migrations"
last_mig="$(ls "$mig_dir" 2>/dev/null | grep -Eo '^[0-9]+' | sort -n | tail -n 1 || true)"
mig_num="$(printf '%03d' $(( 10#${last_mig:-0} + 1 )))"

# template path (relative to templates/) -> target path (relative to the repo)
pairs=(
  "server/src/domain/notes/note.ts|$api/src/domain/$P_KEBAB/$S_KEBAB.ts"
  "server/src/domain/notes/note.repository.ts|$api/src/domain/$P_KEBAB/$S_KEBAB.repository.ts"
  "server/src/application/notes/note.use-cases.ts|$api/src/application/$P_KEBAB/$S_KEBAB.use-cases.ts"
  "server/src/infrastructure/repositories/note.repository.pg.ts|$api/src/infrastructure/repositories/$S_KEBAB.repository.pg.ts"
  "server/src/interface/http/routes/notes.routes.ts|$api/src/interface/http/routes/$P_KEBAB.routes.ts"
  "server/tests/idor.test.ts|$api/tests/$P_KEBAB.idor.test.ts"
  "MIGRATION|$api/db/migrations/${mig_num}_${P_SNAKE}.sql"
)
[[ $web != none ]] && pairs+=("client/src/features/notes/use-notes.ts|$web/src/features/$P_KEBAB/use-$P_KEBAB.ts")

for pair in "${pairs[@]}"; do
  dest="$root/${pair#*|}"
  [[ -e $dest ]] && (( !force )) && die "${pair#*|} already exists (use --force to overwrite)"
done

if (( dry_run )); then
  echo "resource: $S_PASCAL / $P_PASCAL (table $P_SNAKE, route /api/$P_KEBAB)"
  for pair in "${pairs[@]}"; do echo "  write ${pair#*|}"; done
  exit 0
fi

for pair in "${pairs[@]}"; do
  src="${pair%%|*}" dest="$root/${pair#*|}"
  mkdir -p "$(dirname "$dest")"
  if [[ $src == MIGRATION ]]; then
    {
      echo "-- $P_PASCAL: user-owned resource (scaffolded). Replace the example columns."
      awk '/^CREATE TABLE notes /,/^CREATE INDEX notes_owner_idx/' "$tpl/server/db/migrations/001_init.sql"
    } | rename > "$dest"
  else
    rename < "$tpl/$src" > "$dest"
  fi
  echo "wrote ${pair#*|}"
done

# The generated code imports these shared modules; they come from earlier tasks.
missing=()
for dep in src/domain/errors.ts src/application/policies/ownership.ts src/application/ports/field-encryptor.ts \
           src/interface/http/middleware/require-auth.ts tests/helpers.ts; do
  [[ -e "$root/$api/$dep" ]] || missing+=("$api/$dep")
done
[[ $web != none && ! -e "$root/$web/src/shared/lib/api-client.ts" ]] && missing+=("$web/src/shared/lib/api-client.ts")

cat <<EOF

Next steps:
1. Replace the example fields (title, body/body_enc) with the real ones in every
   generated file: entity, input type, zod schema, DTO, SQL, AAD context, tests, hooks.
   Keep encryption only on sensitive columns; drop #crypto if none are sensitive.
2. Mount the router in $api/src/interface/http/app.ts:
     app.use('/api/$P_KEBAB', requireAuth(sessions), requireMfa, ${P_CAMEL}Router($P_CAMEL));
   and add '$P_CAMEL: ${S_PASCAL}UseCases' to AppDeps.
3. Wire the composition root ($api/src/main.ts):
     make${S_PASCAL}UseCases({ $P_CAMEL: new Pg${S_PASCAL}Repository(pool, encryptor), now, newId })
4. Apply migration ${mig_num}_${P_SNAKE}.sql, then run typecheck, lint and the tests.
EOF
if (( ${#missing[@]} )); then
  echo
  echo "Warning: the generated code imports files that do not exist yet:"
  printf '  %s\n' "${missing[@]}"
  echo "Copy them from $tpl first (see references/architecture.md)."
fi
