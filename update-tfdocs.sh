#!/usr/bin/env bash
# Regenerate the terraform-docs block in README.md. CI runs this and fails if the working tree changes, so run it whenever variables or outputs move.
set -euo pipefail

terraform-docs -c .tf-docs.yaml .
