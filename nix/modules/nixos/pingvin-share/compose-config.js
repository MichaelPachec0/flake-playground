// Compose runtime config.yaml.
// argv[1] = base settings JSON path, argv[2] = output path,
// argv[3] = path to backend's bundled `yaml` package.
// PINGVIN_SECRET_KEYS: comma-separated "category.name" keys; each value is
// in $CREDENTIALS_DIRECTORY/<category.name>. Merge into base settings,
// emit YAML.
const fs = require("fs");
const path = require("path");

const [, , baseJsonPath, outPath, yamlModulePath] = process.argv;
const YAML = require(yamlModulePath);

const base = JSON.parse(fs.readFileSync(baseJsonPath, "utf8"));

const credDir = process.env.CREDENTIALS_DIRECTORY;
const secretKeys = (process.env.PINGVIN_SECRET_KEYS || "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

for (const dotted of secretKeys) {
  const value = fs.readFileSync(path.join(credDir, dotted), "utf8").trim();
  const segments = dotted.split(".");
  if (segments.length !== 2) {
    throw new Error(
      `pingvin-share secrets: key "${dotted}" must be exactly ` +
        `"category.name" (2 dot-separated segments); got ${segments.length}.`,
    );
  }
  const [category, name] = segments;
  base[category] = base[category] || {};
  base[category][name] = value;
}

// ConfigService.migrateInitUser (backend/dist/src/config/config.service.js)
// always reads yamlConfig.initUser.enabled with no guard for initUser being
// absent; any non-empty `settings` then crashes the backend on boot
// ("Cannot read properties of undefined (reading 'enabled')") without this.
// Fill a safe default (disabled) without overwriting a user-provided
// initUser.
if (!base.initUser || typeof base.initUser.enabled === "undefined") {
  base.initUser = Object.assign({enabled: false}, base.initUser || {});
}

fs.writeFileSync(outPath, YAML.stringify(base), {mode: 0o600});
