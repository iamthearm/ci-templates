import { writeFileSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';

const config = JSON.parse(process.env.CONFIG_JSON);
const imageRef = process.env.IMAGE_REF;
const caddyHost = process.env.VPS_HOST;
const outDir = process.env.OUT_DIR;

if (!imageRef || !caddyHost || !outDir) {
  console.error('render-compose.mjs requires CONFIG_JSON, IMAGE_REF, VPS_HOST and OUT_DIR env vars');
  process.exit(1);
}

mkdirSync(outDir, { recursive: true });

const d = config.deploy;

// Generated file — app authors never hand-write this. Keeping the shape fixed (one service,
// one edge network) means we don't need a YAML library just to emit it.
const compose = `services:
  ${d.service_name}:
    image: ${imageRef}
    env_file: .env
    expose:
      - "${d.port}"
    networks: [edge]
    restart: unless-stopped
    labels:
      caddy: ${caddyHost}
      caddy.handle_path: "${d.path_prefix}/*"
      caddy.handle_path.0_reverse_proxy: "{{upstreams ${d.port}}}"

networks:
  edge:
    external: true
`;

writeFileSync(resolve(outDir, 'docker-compose.yml.new'), compose);

const required = (d.env && d.env.required) || [];
writeFileSync(resolve(outDir, 'required-env.txt'), required.length ? required.join('\n') + '\n' : '');

console.log(`Rendered compose file for '${config.app_name}' -> ${outDir}/docker-compose.yml.new`);
console.log(compose);
