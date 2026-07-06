import { readFileSync, appendFileSync } from 'node:fs';
import yaml from 'js-yaml';

const [, , configPath] = process.argv;

function fail(message) {
  console.error(`::error::Invalid deploy config (${configPath}): ${message}`);
  process.exit(1);
}

if (!configPath) {
  fail('usage: validate-config.mjs <path-to-deploy.config.yml>');
}

let raw;
try {
  raw = readFileSync(configPath, 'utf8');
} catch (err) {
  fail(`could not read file: ${err.message}`);
}

let config;
try {
  config = yaml.load(raw);
} catch (err) {
  fail(`could not parse YAML: ${err.message}`);
}

if (typeof config !== 'object' || config === null) {
  fail('top-level document must be a YAML mapping');
}

function get(obj, path) {
  return path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
}

function requireField(path, type) {
  const value = get(config, path);
  if (value === undefined || value === null) fail(`missing required field '${path}'`);
  if (type === 'array' && !Array.isArray(value)) fail(`field '${path}' must be an array`);
  else if (type !== 'array' && typeof value !== type) fail(`field '${path}' must be a ${type}`);
  return value;
}

requireField('version', 'number');
if (config.version !== 1) fail(`unsupported 'version': ${config.version} (only 1 is supported)`);

requireField('app_name', 'string');
if (!/^[a-z0-9-]+$/.test(config.app_name)) {
  fail(`'app_name' (${config.app_name}) must match [a-z0-9-]+`);
}

requireField('build.dockerfile', 'string');
config.build.context ??= '.';
config.build.args ??= {};

requireField('test.enabled', 'boolean');
if (config.test.enabled) {
  requireField('test.command', 'string');
}
config.test.image ??= null;
config.test.working_directory ??= '.';

config.unity ??= {};
config.unity.enabled ??= false;
if (config.unity.enabled) {
  requireField('unity.version', 'string');
  requireField('unity.license_secret_name', 'string');
  config.unity.test_mode ??= 'editmode';
  if (!['editmode', 'playmode', 'both'].includes(config.unity.test_mode)) {
    fail("'unity.test_mode' must be one of: editmode, playmode, both");
  }
}

requireField('deploy.enabled', 'boolean');
if (config.deploy.enabled) {
  requireField('deploy.port', 'number');
  requireField('deploy.health_check.path', 'string');

  config.deploy.service_name ??= 'app';
  config.deploy.path_prefix ??= `/${config.app_name}`;
  if (!config.deploy.path_prefix.startsWith('/')) {
    fail("'deploy.path_prefix' must start with '/'");
  }
  config.deploy.vps_dir ??= `/opt/apps/${config.app_name}`;

  config.deploy.health_check.expected_status ??= 200;
  config.deploy.health_check.timeout_seconds ??= 5;
  config.deploy.health_check.retries ??= 10;
  config.deploy.health_check.retry_interval_seconds ??= 3;

  config.deploy.env ??= {};
  config.deploy.env.required ??= [];
  config.deploy.env.optional ??= [];
}

console.log(`Validated deploy config for '${config.app_name}':`);
console.log(JSON.stringify(config, null, 2));

const json = JSON.stringify(config);
if (process.env.GITHUB_OUTPUT) {
  appendFileSync(process.env.GITHUB_OUTPUT, `config=${json}\n`);
} else {
  console.log(json);
}
