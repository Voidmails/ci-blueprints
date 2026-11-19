// Stand-in for `nest build`: emits dist/main.js.
const fs = require('node:fs');

fs.rmSync('dist', { recursive: true, force: true });
fs.cpSync('src', 'dist', { recursive: true });
