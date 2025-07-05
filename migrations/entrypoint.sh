#!/bin/sh
set -e
echo "Starting Flyway"

# Execute the passed arguments (default to Flyway commands)
exec flyway "$@"

echo "Flyway completed successfully.."