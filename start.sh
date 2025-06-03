#!/bin/sh
set -e

# Check required env vars
if [ -z "$CFX_RPC_URL" ] || [ -z "$CFX_NETWORK_ID" ] || [ -z "$CORE_BRIDGE" ] || [ -z "$PRIVATE_KEY" ]; then
  echo "Error: Required environment variables are not set"
  echo "Please ensure CFX_RPC_URL, CFX_NETWORK_ID, CORE_BRIDGE, and PRIVATE_KEY are set"
  exit 1
fi

# Connectivity check
echo "Checking connectivity to $CFX_RPC_URL ..."
if curl --fail --max-time 10 "$CFX_RPC_URL" > /dev/null; then
  echo "Connectivity check to $CFX_RPC_URL succeeded."
else
  echo "ERROR: Connectivity check to $CFX_RPC_URL failed!"
  exit 1
fi

# Start both syncers in the background
node service/eSpacePoolStatusSyncer.js 2>&1 | sed 's/^/[eSpacePoolStatusSyncer] /' &
node service/votingEscrowSyncer.js 2>&1 | sed 's/^/[VotingEscrowSyncer] /' &

# Wait for all background jobs (so the container doesn't exit)
wait 