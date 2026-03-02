#!/usr/bin/env node
'use strict';
const path = require('path');
const { spawnSync } = require('child_process');
const bin = path.join(__dirname, 'bin', 'devswarm');
const result = spawnSync(bin, process.argv.slice(2), { stdio: 'inherit' });
process.exit(result.status ?? 1);
