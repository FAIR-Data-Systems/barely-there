#!/bin/bash
set -e

echo "=== Starting Severance Internal ==="

# Ensure the queries directory exists (as root, so we can create it if needed)
mkdir -p /queries

# Seed demo queries on FIRST run only
if [ -z "$(ls -A /queries 2>/dev/null)" ]; then
    echo "First run detected → copying demo queries to your ./queries folder on the host..."
    cp -r --no-preserve=ownership /demo-queries/* /queries/
    echo "Demo queries seeded successfully."
else
    echo "Queries folder already exists on host → using your version."
fi

# Now fix ownership and permissions so the host user can edit everything
echo "Fixing ownership on /queries to match host user (${UID:-1000}:${GID:-1000})..."
chown -R "${UID:-1000}:${GID:-1000}" /queries
chmod -R u+rwX /queries

echo "Running as user ID: $(id -u)"

# Run the app as the correct (non-root) user
exec ruby innie.rb "$@"