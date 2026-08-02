#!/usr/bin/env bash
#shellcheck disable=SC2001
set -euo pipefail
: "${BRANCH_PREFIX? BRANCH_PREFIX is required}"
: "${REPOSITORY? REPOSITORY is required}"=
: "${GH_TOKEN? GH_TOKEN is required}"

REPO_OWNER=$(dirname -- "$REPOSITORY")
REPO_NAME=$(basename -- "$REPOSITORY")

# Ensure we don't delete too much.
if [[ -z "$BRANCH_PREFIX" ]]; then
	printf "\x1B[31mBranch prefix is empty. Refusing to delete branches.\x1B[m\n"
	exit 1
fi

if [[ "$BRANCH_PREFIX" = "main" ]] || [[ "$BRANCH_PREFIX" = "master" ]]; then
	printf "\x1B[31mBranch prefix is main or master. Refusing to delete branches.\x1B[m\n"
	exit 1
fi

# Find the branches to delete.
echo "Searching for branches..."
refs=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/git/matching-refs/heads/${BRANCH_PREFIX}" --jq '.[].ref')
branches=$(sed 's#^refs/heads/##' <<<"$refs")

echo "Found branches:"
sed 's/^/  /' <<<"$branches"

# Delete the branches.
num_deleted=0
branches_deleted=""
while read -r ref; do
	printf "Deleting %s...\n" "$ref"
	gh api --method DELETE "repos/${REPO_OWNER}/${REPO_NAME}/git/${ref}"
	num_deleted=$(( num_deleted + 1 ))
	branches_deleted="${branches_deleted}"$'\n'"$(sed 's#^refs/heads/##' <<<"$ref")"
done <<<"$refs"

# Set outputs.
EOF_KEY=$(uuidgen | tr -d '-')
{
	echo "count=${num_deleted}"
	echo "branches<<${EOF_KEY}"
	sed '/^$/d' <<<"$branches_deleted"
	echo "${EOF_KEY}"
} >>"$GITHUB_OUTPUT"
