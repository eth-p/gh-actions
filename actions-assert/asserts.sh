#!/usr/bin/env bash
#shellcheck disable=SC2016
set -euo pipefail
declare ACTIONS_ASSERT_ASSERTIONS
declare ACTIONS_ASSERT_OUTPUTS_INPUT
declare _assert_name _assert_run _assert_var _assert_output _assert_is_yaml
declare _match_op _match_expr
declare _matchopt_negate _matchopt_debuglvl
declare _out_color
declare _out_prefix

# ------------------------------------------------------------------------------
_check_stdout=$(mktemp)
_check_stderr=$(mktemp)

cleanup() {
	rm -rf "$_check_stdout" "$_check_stderr" 2>/dev/null || true
}

trap 'cleanup' EXIT
# ------------------------------------------------------------------------------

if [[ "${ACTIONS_RUNNER_DEBUG:-}" ]]; then
	debug() {
		echo "${_matchopt_debuglvl} $1" 1>&2
	}
else
	debug() { :; }
fi

# Prints an error message and exits.
fatal() {
	printf "\x1B[31m%s:\x1B[m\n" "$1"
	yq --colors '... style=""' <<<"$_assert_yaml" |
		sed 's/^/\x1B[31m │ \x1B[m/; s/$/\x1B[m/'
	exit 2
}

# Prints one input assertion per line.
input_assertions() {
	yq --indent=0 '.[] | .. style="flow" | .. comments=""' <<<"$ACTIONS_ASSERT_ASSERTIONS"
}

# Converts an input assertion into shell variables with the prefix `_assert_`.
parse_assert_root() {
	yq --output-format=shell '
		["is"] as $yaml_vars |
		(.name = .name // "") |
		(.run = .run // "") |
		(.var = .var // "") |
		(.output = .output // "") |
		(.is = .is // []) |

		# Ensure "is" is a map.
		with(.is; select(kind == "scalar") | . = [.]) |
		with(.is; select(kind == "seq") | . = {"all": .}) |

		# Re-emit specific keys as yaml.
		(. |= with_entries(with(.;
			select(.key as $key | ($yaml_vars | any_c(. == $key))) |
			.key = (.key + "_yaml") |
			.value = (.value | .. style="flow" | @yaml | trim)
		))) |


		# Convert to bash vars.
		(. |= with_entries(.key |= "_assert_" + (. | downcase)))
	' <<<"$1"
}

parse_assert_match() {
	yq --output-format=shell '
		with(.; select(kind == "scalar") | . = {.: ""}) |
		to_entries |
		{
			"_match_op": (.0.key),
			"_match_expr": (.0.value | @yaml | trim)
		}
	' <<<"$1"
}

# ------------------------------------------------------------------------------
# Matcher:
# ------------------------------------------------------------------------------

do_match() {
	local __prev_debuglvl="$_matchopt_debuglvl"
	_matchopt_debuglvl+="+"

	local __expr_yaml="$1"
	case "$__expr_yaml" in
	"ok") __expr_yaml="{not: failed}" ;;
	"not empty") __expr_yaml="{not: empty}" ;;
	esac

	eval "$(parse_assert_match "$__expr_yaml")"

	debug "OP: ${_match_op} :: ${_match_expr}"
	"do_match_op:${_match_op}" "$_match_expr"
	_matchopt_debuglvl="$__prev_debuglvl"
}

# "all" combinator.
# All matchers within this must pass.
do_match_op:all() {
	local __expr_yaml="$1"
	while read -r __expr_yaml; do
		# TODO HANDLE ALL
		do_match "$__expr_yaml"
	done < <(yq '.[] | @yaml | trim' <<<"$1")
}

do_match_op:not() {
	local __prev_matchopt_negate="$_matchopt_negate"
	_matchopt_negate=true
	do_match "$_match_expr"
	if [[ "$_failed" = true ]]; then
		_failed=false
		debug "-> PASS"
	else
		_failed=true
		debug "-> FAIL"
	fi
	_matchopt_negate="$__prev_matchopt_negate"
}

# Match standard output.
do_match_op:stdout() {
	local __prev_matchopt_target="$_matchopt_target"
	_matchopt_target="$_check_stdout" # Inner expressions should target STDOUT.
	debug "Target=stdout"
	do_match "$1"
	_matchopt_target="$__prev_matchopt_target"
}

# Match target is empty.
do_match_op:empty() {
	if [[ "$(sed '/^$/d' <"$_matchopt_target" | wc -c)" -eq 0 ]]; then
		_failed=false
		debug "-> PASS"
	else
		_failed=true
		debug "-> FAIL"
	fi
}

# Match target is equal to text.
do_match_op:equal() {
	local __value
	__value=$(yq -r "." <<<"$1")
	if [[ "$(cat "${_matchopt_target}")" = "$__value" ]]; then
		_failed=false
		debug "-> PASS"
	else
		_failed=true
		debug "-> FAIL"
	fi
}

# Match target contains substring.
do_match_op:contains() {
	local __value
	__value=$(yq -r "." <<<"$1")
	if grep -qF -- "$__value" "${_matchopt_target}"; then
		_failed=false
		debug "-> PASS"
	else
		_failed=true
		debug "-> FAIL"
	fi
}

# Match target contains line.
do_match_op:contains-line() {
	local __value
	__value=$(yq -r "." <<<"$1")
	if grep -qFx -- "$__value" "${_matchopt_target}"; then
		_failed=false
		debug "-> PASS"
	else
		_failed=true
		debug "-> FAIL"
	fi
}

# Match command exited unsuccessfully.
do_match_op:failed() {
	if [[ -z "$_check_status" ]]; then
		fatal "Can only check failure status of 'run' assertions."
	fi

	if [[ "$_check_status" -ne 0 ]]; then
		_failed=false
		debug "-> PASS"
	else
		_failed=true
		debug "-> FAIL"
	fi
}

# ------------------------------------------------------------------------------
# Assertion Types:
# ------------------------------------------------------------------------------

do_assert() {
	if [[ -n "$_assert_run" ]]; then
		do_assert:run
	elif [[ -n "$_assert_var" ]]; then
		do_assert:var
	elif [[ -n "$_assert_output" ]]; then
		do_assert:output
	else
		fatal "Unknown assertion type"
	fi

	# Print the result.
	if [[ "$_failed" = true ]]; then
		_any_fail=true
		__color=$'\x1B[31m'
		printf "\x1B[31mFAIL: \x1B[m%s\n" "${_assert_name:-Assert ${_iter_number}}"

		if [[ -n "$_failed_reason" ]]; then
			printf "%s ├─ Reason: %s\x1B[m\n" "$__color" "$_failed_reason"
		fi

		# Print the failing assertion.
		printf "%s ├─ Assertion:\x1B[m\n" "$__color"
		yq --colors '... style=""' <<<"$_assert_yaml" |
			sed 's/^/'"$__color"' │   │ \x1B[m/; s/$/\x1B[m/'
		printf "%s │   ╵ \x1B[m\n" "$__color"
	else
		__color=$'\x1B[32m'
		printf "%sPASS: \x1B[m%s\n" "$__color" "${_assert_name:-Assert ${_iter_number}}"
	fi

	# Print the standard output.
	if [[ "$(head -n1 <"$_check_stdout" | wc -c)" -gt 0 ]]; then
		printf "%s ├─ Output:\x1B[m\n" "$__color"
		sed 's/^/'"$__color"' │   │ \x1B[m/; s/$/\x1B[m/' "$_check_stdout"
		printf "%s │   ╵ \x1B[m\n" "$__color"
	fi

	# Print the standard error.
	if [[ "$(head -n1 <"$_check_stderr" | wc -c)" -gt 0 ]]; then
		printf "%s ├─ Stderr:\x1B[m\n" "$__color"
		sed 's/^/'"$__color"' │   │ \x1B[m/; s/$/\x1B[m/' "$_check_stderr"
		printf "%s │   ╵ \x1B[m\n" "$__color"
	fi

	printf "%s ╵ \x1B[m\n" "$__color"
}

do_assert:run() {
	_check_status=0
	bash -eu -o pipefail -c "$_assert_run" \
		>"$_check_stdout" \
		2>"$_check_stderr" ||
		_check_status=$?

	do_match "$_assert_is_yaml"
}

do_assert:var() {
	cat <<<"${!_assert_var}" >"${_check_stdout}"
	do_match "$_assert_is_yaml"
}

do_assert:output() {
	_has_output=$(
		varname="$_assert_output" yq \
			'(keys | any_c(. == strenv(varname)))' \
			<<<"$ACTIONS_ASSERT_OUTPUTS_INPUT"
	)

	if [[ "$_has_output" != "true" ]]; then
		_failed_reason="Output does not exist."
		_failed=true
		return
	fi

	varname="$_assert_output" yq -r '.[strenv(varname)]' \
		<<<"$ACTIONS_ASSERT_OUTPUTS_INPUT" \
		>"$_check_stdout"

	do_match "$_assert_is_yaml"
}

# ------------------------------------------------------------------------------
# Main:
# ------------------------------------------------------------------------------

_any_fail=false
_iter_number=0
while read -r _assert_yaml; do
	_iter_number=$((_iter_number + 1))

	truncate --size=0 "$_check_stderr"
	truncate --size=0 "$_check_stdout"
	_check_status=
	_failed=false
	_failed_reason=
	_matchopt_debuglvl=
	_matchopt_negate=false
	_matchopt_target="${_check_stdout}"

	debug "-- ASSERT: $_assert_yaml"
	eval "$(parse_assert_root "$_assert_yaml")"

	do_assert
done < <(input_assertions)

if [[ "$_any_fail" = "true" ]]; then
	exit 1
fi
