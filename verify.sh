#!/usr/bin/env bash
# verify_rig.sh - The "One-Click" Integrity Checker

CONTAINER_NAME="security-rig-test-$(date +%s)"

echo "--- Spinning up test container for: setup.sh ---"
incus launch images:void/current $CONTAINER_NAME

echo "Waiting for container initialization..."
sleep 5

incus file push setup.sh $CONTAINER_NAME/root/

echo "--- Executing setup.sh inside container ---"
incus exec $CONTAINER_NAME -- bash -x /root/setup.sh

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  echo "---------------------------------------------"
  echo "SUCCESS: Build integrity verified."
  echo "---------------------------------------------"
else
  echo "---------------------------------------------"
  echo "FAILURE: Build failed with exit code $EXIT_CODE."
  echo "Please check the logs above."
  echo "---------------------------------------------"
  exit $EXIT_CODE
fi

echo "--- Cleaning up ---"
incus delete $CONTAINER_NAME --force
