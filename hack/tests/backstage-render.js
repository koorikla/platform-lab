// Offline stand-in for the Backstage scaffolder (v1beta3 templates), used by test_backstage_template.sh.
// Mirrors scaffolder-backend 4.0.0 (Backstage 1.51, what OpenChoreo 1.2.5's image ships) where it matters for a
// template's correctness: nunjucks with `${{ }}` variables, single-expression inputs keep their type, '' -> undefined,
// step `if`, fetch:template (skeleton paths that render empty are skipped, file modes kept), output links with `if`.
// Other actions are not executed: their rendered input is recorded and they return fake outputs.
//
// usage: node backstage-render.js <template.json> <template-dir> <parameters.json> <out-dir>
//   writes <out-dir>/workspace/ (fetch:template result), steps.yaml, output.yaml (JSON, named .yaml for yq)
'use strict';
const fs = require('fs');
const path = require('path');
const nunjucks = require('nunjucks');

const [tplFile, tplDir, paramsFile, outDir] = process.argv.slice(2);
const tpl = JSON.parse(fs.readFileSync(tplFile, 'utf8'));
const parameters = JSON.parse(fs.readFileSync(paramsFile, 'utf8'));
const workspace = path.join(outDir, 'workspace');

const tags = { variableStart: '${{', variableEnd: '}}' };
const env = new nunjucks.Environment(null, { autoescape: false, tags });
// skeleton files render strictly: a typo in values.x must fail the test, not silently become ''
const strictEnv = new nunjucks.Environment(null, { autoescape: false, throwOnUndefined: true, tags });

const isSingleExpression = s => s.startsWith('${{') && s.endsWith('}}') && s.indexOf('${{', 3) === -1;
function renderString(s, ctx) {
  if (isSingleExpression(s)) {
    const dumped = env.renderString(s.replace(/\$\{\{(.+)\}\}/s, '${{ ( $1 ) | dump }}'), ctx);
    return dumped === '' ? undefined : JSON.parse(dumped);
  }
  const out = env.renderString(s, ctx);
  return out === '' ? undefined : out;
}
const render = (input, ctx) =>
  input === undefined ? undefined
    : JSON.parse(JSON.stringify(input), (_k, v) => (typeof v === 'string' ? renderString(v, ctx) : v));
const isTruthy = v => !(v === undefined || v === null || v === false || v === '' || v === 'false' || v === 0);

function fetchTemplate(input) {
  if (input.copyWithoutTemplating || input.copyWithoutRender || input.templateFileExtension || input.cookiecutterCompat) {
    throw new Error('backstage-render.js: fetch:template option not emulated');
  }
  const src = path.resolve(tplDir, input.url);
  const dst = path.resolve(workspace, input.targetPath || '.');
  const ctx = { values: input.values || {} };
  const walk = rel => fs.readdirSync(path.join(src, rel), { withFileTypes: true }).flatMap(d => {
    const p = rel ? `${rel}/${d.name}` : d.name;
    return d.isDirectory() ? [`${p}/`, ...walk(p)] : [p];
  });
  for (const entry of walk('')) {
    const out = strictEnv.renderString(entry, ctx);
    if (out === '' || out.startsWith('/') || out.includes('//')) continue; // empty path segment = skipped
    const target = path.join(dst, out);
    if (entry.endsWith('/')) { fs.mkdirSync(target, { recursive: true }); continue; }
    const file = path.join(src, entry);
    const buf = fs.readFileSync(file);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    const content = buf.includes(0) ? buf : strictEnv.renderString(buf.toString('utf8'), ctx);
    fs.writeFileSync(target, content, { mode: fs.statSync(file).mode });
  }
  return {};
}

// "host?owner=o&repo=r" -> { host, owner, repo }
function parseRepoUrl(u) {
  const [host, query] = u.split('?');
  const q = new URLSearchParams(query);
  return { host, owner: q.get('owner'), repo: q.get('repo') };
}

const actions = {
  'fetch:template': fetchTemplate,
  'publish:gitlab': i => {
    const { host, owner, repo } = parseRepoUrl(i.repoUrl);
    const remoteUrl = `https://${host}/${owner}/${repo}`;
    return { remoteUrl, repoContentsUrl: `${remoteUrl}/-/blob/${i.defaultBranch || 'master'}`, projectId: 1 };
  },
  'publish:github': i => {
    const { host, owner, repo } = parseRepoUrl(i.repoUrl);
    const remoteUrl = `https://${host}/${owner}/${repo}`;
    return { remoteUrl, repoContentsUrl: `${remoteUrl}/blob/${i.defaultBranch || 'master'}` };
  },
  'catalog:register': () => {
    const info = fs.readFileSync(path.join(workspace, 'catalog-info.yaml'), 'utf8');
    const name = info.match(/^metadata:\n(?:.*\n)*?  name: (.+)$/m)[1];
    return { entityRef: `component:default/${name}` };
  },
};

const ctx = { parameters, steps: {}, user: { ref: 'user:default/tester', entity: { metadata: { name: 'tester' } } } };
const steps = [];
fs.mkdirSync(workspace, { recursive: true });
for (const step of tpl.spec.steps) {
  if (!actions[step.action]) throw new Error(`step ${step.id}: action ${step.action} not emulated`);
  const skipped = step.if !== undefined && !isTruthy(typeof step.if === 'string' ? renderString(step.if, ctx) : step.if);
  const input = skipped ? null : render(step.input, ctx);
  steps.push({ id: step.id, action: step.action, skipped, input });
  if (!skipped) ctx.steps[step.id] = { output: actions[step.action](input) };
}
const output = render(tpl.spec.output || {}, ctx);
for (const k of ['links', 'text']) {
  if (Array.isArray(output[k])) output[k] = output[k].filter(i => i.if === undefined || isTruthy(i.if)).map(({ if: _, ...i }) => i);
}
fs.writeFileSync(path.join(outDir, 'steps.yaml'), JSON.stringify(steps, null, 2));
fs.writeFileSync(path.join(outDir, 'output.yaml'), JSON.stringify(output, null, 2));
