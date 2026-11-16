#!/usr/bin/env bash
# Deploy the given stacks on the Docker host: check out the commit, then bring each stack up and wait
# until its containers are running and healthy. Exits non-zero if any stack fails, after trying all of them.

REMOTE_USER="root"
REMOTE_HOST="jailmaker-docker.cosmos.cboxlab.com"
REMOTE_PATH="/opt/stacks"
# "docker compose up --wait" gives up as soon as one container is unhealthy or exits, even when Docker
# restarts it a moment later (an app that starts before its database is ready). After such a failure the
# stack gets this long to settle before the deploy counts as failed.
SETTLE_SECONDS="${SETTLE_SECONDS:-600}"

if [ -z "$GIT_COMMIT_SHA" ]; then
    echo "❌ GIT_COMMIT_SHA is not set."
    exit 1
fi

if ! ssh "$REMOTE_USER@$REMOTE_HOST" bash -s -- "$REMOTE_PATH" "$GIT_COMMIT_SHA" << 'EOF'
    set -e
    cd "$1"
    git fetch origin
    git checkout "$2"
EOF
then
    echo "❌ Could not check out $GIT_COMMIT_SHA on $REMOTE_HOST."
    exit 1
fi

FAILED=()
for STACK in "$@"; do
    echo "🚀 Deploying stack: $STACK"
    if ssh "$REMOTE_USER@$REMOTE_HOST" bash -s -- "$REMOTE_PATH/$STACK" "$SETTLE_SECONDS" << 'EOF'
      cd "$1" || exit 1
      settle="$2"

      # Containers that are not fine: not running (a one-shot container that exited 0 is fine), or running
      # with a healthcheck that is not healthy yet.
      not_ready() {
        docker compose ps -a --format '{{.Name}}|{{.State}}|{{.Health}}|{{.ExitCode}}' \
          | awk -F'|' '!(($2 == "running" && ($3 == "" || $3 == "healthy")) || ($2 == "exited" && $4 == "0")) { print $1 " (" $2 ($3 == "" ? "" : ", " $3) ")" }'
      }

      if docker compose up -d --wait; then
        echo "✅ up and healthy"
        exit 0
      fi

      echo "⚠️ 'docker compose up --wait' failed; giving the stack up to ${settle}s to settle"
      deadline=$((SECONDS + settle))
      good=0
      while [ "$SECONDS" -lt "$deadline" ]; do
        bad="$(not_ready)"
        if [ -z "$bad" ]; then
          # Three clean samples in a row, so a crash-looping container without a healthcheck that happens
          # to be "running" at one instant does not pass.
          good=$((good + 1))
          if [ "$good" -ge 3 ]; then
            echo "✅ settled after a slow or restarted start"
            docker compose ps -a
            exit 0
          fi
        else
          good=0
          echo "waiting for: $(echo "$bad" | tr '\n' ' ')"
        fi
        sleep 15
      done

      echo "❌ stack did not become healthy within ${settle}s"
      docker compose ps -a
      # Container logs are not printed here: this repository's Actions logs are public.
      echo "not ready: $(not_ready | tr '\n' ' ')"
      echo "Read the logs on the host: docker logs --tail 50 <container>"
      exit 1
EOF
    then
        echo "✅ $STACK deployed"
    else
        echo "❌ $STACK failed"
        FAILED+=("$STACK")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "❌ Failed stacks: ${FAILED[*]}"
    exit 1
fi
