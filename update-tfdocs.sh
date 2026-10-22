#!/usr/bin/env bash
# Regenerate the terraform-docs block in README.md. Run it whenever variables or outputs move.
set -euo pipefail

terraform-docs -c .tf-docs.yaml .
