const { validate } = require('./inputs');

const passed = validate((input, reason) => {
    console.log(`::error title=Error in eth-p/gh-actions/cleanup-hook::Input '${input}': ${reason}.`);
});

if (!passed) {
    process.exit(1);
}
