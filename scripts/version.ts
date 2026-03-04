#!/usr/bin/env bun
/**
 * Update the version everywhere:
 *   bun run version 0.4.0
 *   bun run version patch   (0.3.0 → 0.3.1)
 *   bun run version minor   (0.3.0 → 0.4.0)
 *   bun run version major   (0.3.0 → 1.0.0)
 */

const ROOT = import.meta.dir + "/..";
const VERSION_FILE = `${ROOT}/VERSION`;

const current = (await Bun.file(VERSION_FILE).text()).trim();
const arg = process.argv[2];

if (!arg) {
  console.log(`Current version: ${current}`);
  process.exit(0);
}

function bump(version: string, part: "major" | "minor" | "patch"): string {
  const [major, minor, patch] = version.split(".").map(Number);
  switch (part) {
    case "major": return `${major + 1}.0.0`;
    case "minor": return `${major}.${minor + 1}.0`;
    case "patch": return `${major}.${minor}.${patch + 1}`;
  }
}

const next = ["major", "minor", "patch"].includes(arg)
  ? bump(current, arg as "major" | "minor" | "patch")
  : arg;

if (!/^\d+\.\d+\.\d+$/.test(next)) {
  console.error(`Invalid version: ${next}`);
  process.exit(1);
}

// 1. VERSION file
await Bun.write(VERSION_FILE, next + "\n");

// 2. All package.json files
const packageJsons = [
  `${ROOT}/packages/shared/package.json`,
  `${ROOT}/packages/cli/package.json`,
];

for (const path of packageJsons) {
  const pkg = await Bun.file(path).json();
  pkg.version = next;
  await Bun.write(path, JSON.stringify(pkg, null, 2) + "\n");
}

// 3. GeneratedVersion.swift
const swiftPath = `${ROOT}/packages/desktop/AgentHub/AgentHub/GeneratedVersion.swift`;
await Bun.write(
  swiftPath,
  `// Auto-generated from VERSION file — do not edit\nenum GeneratedVersion {\n    static let string = "${next}"\n}\n`
);

// 4. Xcode MARKETING_VERSION in pbxproj
const pbxprojPath = `${ROOT}/packages/desktop/AgentHub/AgentHub.xcodeproj/project.pbxproj`;
const pbxproj = await Bun.file(pbxprojPath).text();
const updated = pbxproj.replace(
  /MARKETING_VERSION = [\d.]+;/g,
  `MARKETING_VERSION = ${next};`
);
await Bun.write(pbxprojPath, updated);

console.log(`${current} → ${next}`);
