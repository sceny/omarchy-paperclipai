#!/bin/bash
# Exercises dev/follow-develop against throwaway bare repos in a temp dir. No
# network, no real shell, no host plugins: every path is overridden.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$HERE/../dev/follow-develop
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export FOLLOW_PLUGINS_DIR=$T/plugins FOLLOW_STATE_DIR=$T/state
export FOLLOW_PLUGINS="p.one p.two p.three p.link p.plain"
export FOLLOW_RESCAN_CMD="touch $T/rescanned"
export FOLLOW_VALIDATE_CMD="$T/validate"
printf '#!/bin/bash\n[[ -f "$1/ok" ]]\n' >"$T/validate"; chmod +x "$T/validate"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }
run() { bash "$SCRIPT" run >"$T/out" 2>&1; echo $? >"$T/rc"; }

mkdir -p "$FOLLOW_PLUGINS_DIR" "$T/work"
for p in p.one p.two p.three; do
  git init -q --bare -b main "$T/$p.git"
  git clone -q "$T/$p.git" "$T/work/$p" 2>/dev/null
  ( cd "$T/work/$p" && git switch -q -c main && touch ok && git add ok && git commit -qm init \
    && git push -q origin main && git switch -q -c develop && git push -q origin develop )
  git clone -q -b develop "$T/$p.git" "$FOLLOW_PLUGINS_DIR/$p"
done
mkdir "$T/target" "$FOLLOW_PLUGINS_DIR/p.plain"; ln -s "$T/target" "$FOLLOW_PLUGINS_DIR/p.link"

push_change() { ( cd "$T/work/$1" && git switch -q develop && echo "$2" >f && git add f && git commit -qm "$2" && git push -q origin develop ); }

run
check "up to date: rc 0, no rescan" '[[ $(cat $T/rc) == 0 && ! -e $T/rescanned ]]'
check "symlink and non-git copy are skipped" 'grep -q "symlink" $T/out && grep -q "not a git checkout" $T/out'

push_change p.one c1
push_change p.two c1
run
check "merge on develop reaches p.one" '[[ $(git -C $FOLLOW_PLUGINS_DIR/p.one rev-parse HEAD) == $(git -C $T/p.one.git rev-parse develop) ]]'
check "rc 0 and one rescan" '[[ $(cat $T/rc) == 0 && -e $T/rescanned ]]'
check "log has an updated line with from/to" 'jq -e "select(.plugin==\"p.one\" and .result==\"updated\" and .from!=.to)" $FOLLOW_STATE_DIR/follow-develop.jsonl >/dev/null'
rm -f "$T/rescanned"

git -C "$FOLLOW_PLUGINS_DIR/p.two" switch -q -c feature
push_change p.two c2
run
check "feature branch left alone" '[[ $(git -C $FOLLOW_PLUGINS_DIR/p.two symbolic-ref --short HEAD) == feature ]] && grep -q "not develop" $T/out'
git -C "$FOLLOW_PLUGINS_DIR/p.two" switch -q develop

echo dirty >>"$FOLLOW_PLUGINS_DIR/p.three/ok"
push_change p.three c1
run
check "dirty checkout left alone" 'grep -q "local changes" $T/out && [[ ! -e $FOLLOW_PLUGINS_DIR/p.three/f ]]'
git -C "$FOLLOW_PLUGINS_DIR/p.three" checkout -q -- ok

( cd "$T/work/p.three" && git rm -q ok && git commit -qm "break manifest" && git push -q origin develop )
before=$(git -C "$FOLLOW_PLUGINS_DIR/p.three" rev-parse HEAD)
run
check "failed validation rolls back and exits 1" '[[ $(git -C $FOLLOW_PLUGINS_DIR/p.three rev-parse HEAD) != $(git -C $T/p.three.git rev-parse develop) && $(cat $T/rc) == 1 ]] && grep -q rolled-back $T/out'
check "rollback target is the pre-pass commit" '[[ $(git -C $FOLLOW_PLUGINS_DIR/p.three rev-parse HEAD) == $before ]]'

run
check "second pass is idempotent (same result, still rolled back)" '[[ $(cat $T/rc) == 1 ]]'

echo "failures: $fails"
exit $((fails > 0))
