#!/usr/bin/env node
import { Command } from 'commander';
import { registerSpawn } from './commands/spawn.js';
import { registerStatus } from './commands/status.js';
import { registerEval } from './commands/eval.js';
import { registerComplete } from './commands/complete.js';

const program = new Command();

program
  .name('nexum')
  .description('Nexum task orchestration CLI')
  .version('0.0.0');

registerSpawn(program);
registerStatus(program);
registerEval(program);
registerComplete(program);

program.parse(process.argv);
