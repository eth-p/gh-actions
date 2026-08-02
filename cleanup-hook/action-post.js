const { spawnSync, execSync } = require('child_process');
const { createHash } = require('crypto');
const { join } = require('path');
const { writeFileSync } = require('fs');

const { inputs, validate } = require('./inputs');

/**
 * Runs the cleanup hook as a shell script.
 *
 * @param {*} shell The shell info.
 */
function runShell(shell) {
    const script = inputs.run;
    const scriptHash = createHash('sha256').update(script).digest('hex');
    const scriptFile = join(process.env.RUNNER_TEMP, `cleanup_hook_${scriptHash}.${shell.extension}`);

    const args = shell.args
        .map(v => v.replace("{0}", scriptFile));

    writeFileSync(scriptFile, script, 'utf8');
    printScript(script, { shell: shell.args.join(" ") });
    spawnSync(shell.executable, args, {
        cwd: inputs.working_directory,
        stdio: ['ignore', 'inherit', 'inherit'],
    });
}

/**
 * Runs the cleanup hook through an interactive shell session.
 */
function runExecutable() {
    printScript(inputs.run, { shell: inputs.shell.join(" ") });
    execSync(inputs.shell, {
        input: inputs.run,
        cwd: inputs.working_directory,
        stdio: ['pipe', 'inherit', 'inherit'],
    });
}

/**
 * Prints the script to the action's log.
 *
 * @param {string} script The script code.
 * @param {object} extraInfo Extra info to print.
 */
function printScript(script, extraInfo) {
    const scriptLines = script.split("\n", 2);

    console.log(`::group::Run cleanup hook ${scriptLines[0].trim()}`);

    for (const line of scriptLines) {
        console.log(`\x1B[36m${line}\x1B[m`);
    }

    for (const [name, value] of Object.entries(extraInfo ?? {})) {
        console.log(`${name}: ${value}`);
    }

    console.log('::endgroup::');
}

if (validate()) {
    const knownShells = {
        bash: {
            executable: "/usr/bin/bash",
            extension: '.sh',
            args: ["--noprofile", "--norc", "-e", "-o", "pipefail", "{0}"],
        }
    };

    if (Object.hasOwn(knownShells, inputs.shell)) {
        runShell(knownShells[inputs.shell]);
    } else {
        runExecutable();
    }
}
