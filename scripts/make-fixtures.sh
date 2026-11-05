#!/usr/bin/env bash
# Build the fixed synthetic Acme git suite in an empty destination.
#
#   scripts/make-fixtures.sh <empty-directory>
set -euo pipefail
[[ $# == 1 ]] || { echo 'usage: make-fixtures.sh <empty-directory>' >&2; exit 64; }
destination="$1"
mkdir -p "$destination"
shopt -s nullglob dotglob
entries=("$destination"/*)
((${#entries[@]} == 0)) || { echo 'fixture destination must be empty' >&2; exit 1; }
destination="$(cd "$destination" && pwd -P)"
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME='Acme Developer' GIT_COMMITTER_NAME='Acme Developer'
export GIT_AUTHOR_EMAIL='developer@acme.invalid' GIT_COMMITTER_EMAIL='developer@acme.invalid'
export GIT_AUTHOR_DATE='2023-11-14T22:13:20+0000' GIT_COMMITTER_DATE='2023-11-14T22:13:20+0000'
export LC_ALL=C TZ=UTC

g() {
  git -c init.defaultBranch=master -c core.hooksPath=/dev/null -c commit.gpgsign=false \
    -c protocol.file.allow=always "$@"
}
commit() {
  g add .
  g commit -q -m "$1"
}

g init -q "$destination/acme-platform"
cd "$destination/acme-platform"
printf 'Acme platform\n' > README.md
commit 'Create Acme platform'
g checkout -q -b portal
mkdir -p portal
printf 'Acme portal\n' > portal/README.md
commit 'Add Acme portal'
g branch portal-prod
g checkout -q -b api
mkdir -p api apps/console
printf 'Acme API\n' > api/README.md
printf 'Acme console\n' > apps/console/README.md
commit 'Add Acme API and console'
g branch api-prod
g init --bare -q "$destination/acme-origin.git"
g remote add origin "$destination/acme-origin.git"
g push -q origin --all
g checkout -q -b rebased portal
printf 'Acme topic\n' > topic.md
commit 'Add Acme topic'
g tag before-rebase
g push -q origin rebased
g rebase api
g push -q --force origin rebased
g branch old-name master
g branch -m old-name renamed
g checkout -q -b non-app master
printf 'Acme infrastructure\n' > infrastructure.md
commit 'Add Acme infrastructure'
g checkout -q -b from-non-app
printf 'Acme maintenance\n' > maintenance.md
commit 'Add Acme maintenance'
g push -q origin --all
g push -q origin --tags
g checkout -q api
g worktree add -q "$destination/acme-portal-worktree" portal
g clone -q "$destination/acme-origin.git" "$destination/acme-detached"
g -C "$destination/acme-detached" checkout -q --detach origin/api
g clone -q --depth 1 --branch api "file://$destination/acme-origin.git" "$destination/acme-shallow"
g clone -q "$destination/acme-origin.git" "$destination/acme-missing-remote"
g -C "$destination/acme-missing-remote" remote remove origin
