#!/usr/bin/env node
// Copy the repository's skills/ into the package before packing. The npm
// package ships the same four skill folders as the binary embeds.
const fs = require("node:fs");
const path = require("node:path");

const src = path.join(__dirname, "..", "..", "skills");
const dest = path.join(__dirname, "..", "skills");

if (!fs.existsSync(src)) {
  console.error("copy-skills: ../skills is missing");
  process.exit(1);
}
fs.rmSync(dest, { recursive: true, force: true });
fs.cpSync(src, dest, { recursive: true });
for (const name of fs.readdirSync(dest)) {
  if (!fs.existsSync(path.join(dest, name, "SKILL.md"))) {
    console.error(`copy-skills: ${name} has no SKILL.md`);
    process.exit(1);
  }
}
