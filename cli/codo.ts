#!/usr/bin/env bun

const VERSION = "0.1.0";

function printUsage(): void {
  console.error(`Usage: codo <title> [body] [--silent]
       echo '{"title":"..."}' | codo

Options:
  --silent     Suppress notification sound
  --help       Show this help message
  --version    Show version`);
}

function main(): void {
  const args = process.argv.slice(2);

  if (args.includes("--help")) {
    printUsage();
    process.exit(0);
  }

  if (args.includes("--version")) {
    console.error(`codo ${VERSION}`);
    process.exit(0);
  }

  // Placeholder: full implementation in Phase 5
  printUsage();
  process.exit(1);
}

main();
