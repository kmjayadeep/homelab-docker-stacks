#!/usr/bin/env bash

if [ $# -eq 0 ]; then
  echo "❌ No stack names provided. Usage: ./$(basename $0) stack1 stack2 ..."
    exit 1
fi

# Define remote server details
REMOTE_USER="root"
REMOTE_HOST="jailmaker-docker.cosmos.cboxlab.com"
REMOTE_PATH="/opt/stacks"
STACKS="$1"

# Check if commit SHA is provided
if [ -z "$GIT_COMMIT_SHA" ]; then
    echo "❌ GIT_COMMIT_SHA is not set."
    exit 1
fi

# Checkout code
ssh "$REMOTE_USER@$REMOTE_HOST" << EOF
    cd $REMOTE_PATH
    git checkout main
    git pull
    git checkout $GIT_COMMIT_SHA
EOF

# Update docker compose stack
for STACK in "$@"; do
    echo "🚀 Deploying stack: $STACK"
    ssh "$REMOTE_USER@$REMOTE_HOST" << EOF
      cd $REMOTE_PATH/$STACK
      docker compose up -d --wait
EOF
done
