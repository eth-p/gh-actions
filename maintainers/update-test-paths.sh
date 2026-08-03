#!/usr/bin/env bash
#shellcheck disable=SC2001
set -euo pipefail

files_of_action() {
	printf ".github/workflows/test-action-%s.yaml\n" "$(sed -E 's/[^a-z-]+/-/' <<<"$1")"
	find "$1" -type f
}

files_of_workflow() {
	printf ".github/workflows/%s.yaml\n" "$1"
}

actions_in_action() {
	yq -r --no-doc '
		[
			.runs.steps[] // {} |
			select((.uses != null)) |
			(.uses | match("^\$/(.*)$") | .captures[0].string)
		] | sort | unique | .[]
	' "./$1/action.yaml"
}

actions_in_workflow() {
	yq -r --no-doc '
		[
			.jobs[].steps[] // {} |
			select((.uses != null)) |
			(.uses | match("^\$/(.*)$") | .captures[0].string)
		] | sort | unique | .[]
	' "./.github/workflows/${1}.yaml"
}

workflows_in_workflow() {
	yq -r --no-doc '
		[
		.jobs[] // {} |
		select((.uses != null)) |
		(.uses | match("^\$/\.github/workflows/(.*)\.yaml$") | .captures[0].string)
		] | sort | unique | .[]
	' "./.github/workflows/${1}.yaml"
}

declare -A action_seen
declare -A action_files # deep
declare -A action_deps  # deep
declare -A workflow_seen
declare -A workflow_files          # deep
declare -A workflow_deps_actions   # deep
declare -A workflow_deps_workflows # deep

# Scan an action to find its recursive list of dependencies and files.
scan_action_deps() {
	if [[ -n "${action_seen[$1]:-}" ]]; then
		return
	fi

	action_seen[$1]=true

	local hl="$2"$'/\x1B[35m'"action: ${1/\//~}"$'\x1B[m'
	echo "$hl"

	# Add files for the action.
	action_files[$1]=$(files_of_action "$1")
	sed 's#/#~#g; s#^#'"${hl}"'/#' <<<"${action_files[$1]}"

	# Find dependency actions and add their files.
	action_deps[$1]=$(actions_in_action "$1")
	local dep_action
	while read -r dep_action; do
		scan_action_deps "${dep_action}" "$hl"
		action_files[$1]+=$'\n'"${action_files[$dep_action]}"
		action_deps[$1]+=$'\n'"${action_deps[$dep_action]}"
	done < <(sed '/^$/d' <<<"${action_deps[$1]}")

	# Sort and dedupe files.
	action_files[$1]=$(sort -u <<<"${action_files[$1]}")
}

# Scan a workflow to find its recursive list of dependencies and files.
scan_workflow_deps() {
	if [[ -n "${workflow_seen[$1]:-}" ]]; then
		return
	fi

	workflow_seen[$1]=true

	local hl="$2"$'/\x1B[36m'"workflow: ${1}.yaml"$'\x1B[m'
	echo "$hl"

	# Add files for the workflow.
	workflow_files[$1]=$(files_of_workflow "$1")

	# Find dependency workflows and add their files.
	workflow_deps_workflows[$1]=$(workflows_in_workflow "$1")
	local dep_workflow
	while read -r dep_workflow; do
		scan_workflow_deps "${dep_workflow}" "$hl"
		workflow_files[$1]+=$'\n'"${workflow_files[$dep_workflow]}"
		workflow_deps_actions[$1]+=$'\n'"${workflow_deps_actions[$dep_workflow]}"
		workflow_deps_workflows[$1]+=$'\n'"${workflow_deps_workflows[$dep_workflow]}"
	done < <(sed '/^$/d' <<<"${workflow_deps_workflows[$1]}")

	# Find dependency actions and add their files.
	workflow_deps_actions[$1]=$(actions_in_workflow "$1")
	local dep_action
	while read -r dep_action; do
		scan_action_deps "${dep_action}" "$hl"
		workflow_files[$1]+=$'\n'"${action_files[$dep_action]}"
		workflow_deps_actions[$1]+=$'\n'"${action_deps[$dep_action]}"
	done < <(sed '/^$/d' <<<"${workflow_deps_actions[$1]}")

	# Sort and dedupe files.
	workflow_files[$1]=$(sort -u <<<"${workflow_files[$1]}")
}

if ! command -v as-tree &>/dev/null; then
	as_tree() {
		cat
	}
fi

# Iterate through the workflows.
# If any changed file affects the workflow, add the workflow.
for workflow_file in .github/workflows/*.yaml; do
	workflow=$(basename -- "$workflow_file" .yaml)

	case "$workflow" in
		test-action-*) true;;
		test-workflow-*) true;;
		*) continue;;
	esac

	if ! grep -q "# ----- BEGIN DETECTED DEPENDENCIES -----" "$workflow_file"; then
		continue
	fi

	({
		printf "\n"
		scan_workflow_deps "$workflow" "" > >(
			cut -c2- |
			as-tree |
			sed -E 's#([│├─└─])#\x1B[2m\1\x1B[m#g; s#~#/#g'
		)

		# Update the list of files.
		{
			awk '
				{ print }
				/[[:space:]]*# ----- BEGIN DETECTED DEPENDENCIES -----/ { exit }
			' "$workflow_file"
			sed 's/^/      - /' <<<"${workflow_files[$workflow]}"
			awk '
				BEGIN { p=0 }
				/[[:space:]]*# ----- END DETECTED DEPENDENCIES -----/ { p=1 }
				{ if (p == 1) { print } }
			' "$workflow_file"
		} > "${workflow_file}.new"
		mv "${workflow_file}.new" "$workflow_file"
	})

done
