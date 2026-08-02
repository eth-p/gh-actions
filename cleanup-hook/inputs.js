const inputs = {
    run: get('run'),
    shell: get('shell'),
    working_directory: get('working-directory'),
};

/**
 * Gets an action input.
 *
 * @param {string} input The input name.
 * @returns {string|undefined} The input value, or undefined if the input is epmty.
 */
function get(input) {
    const name = "INPUT_" + input.toUpperCase().replace(/-+/g, "_");
    const value = process.env[name];
    return value === '' ? undefined : value;
}

/**
 * Validates the action inputs.
 *
 * @param {(input: string, reason: string) => void} [onInvalid] Called when a parameter is invalid.
 * @returns {boolean} True if the inputs are valid.
 */
function validate(onInvalid) {
    let passed = true;
    function fail(input, reason) {
        passed = false;
        onInvalid?.(input, reason);
    }

    if (inputs.run == null) {
        fail("run", "input is required");
    }

    if (inputs.shell == null) {
        fail("shell", "cannot be empty");
    }

    return passed;
};

module.exports = {
    inputs,
    get,
    validate,
};
