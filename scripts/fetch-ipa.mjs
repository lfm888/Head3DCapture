#!/usr/bin/env node
/**
 * fetch-ipa.mjs — trigger / wait for the GitHub Actions IPA build and download it locally.
 *
 * Usage:
 *   node scripts/fetch-ipa.mjs                 # wait for the latest run (trigger one if none) and download
 *   node scripts/fetch-ipa.mjs --dispatch      # force a new workflow_dispatch run, then wait + download
 *   node scripts/fetch-ipa.mjs --out artifacts # output folder (default: ./artifacts)
 *   node scripts/fetch-ipa.mjs --timeout 45    # max minutes to wait (default 40)
 *
 * Token resolution order: GITHUB_TOKEN env var, then the git credential manager (origin remote).
 * Required scopes: `repo` (classic PAT) — same token used for git push works.
 */
import { execSync } from 'node:child_process';
import { mkdirSync, writeFileSync, copyFileSync, existsSync, readdirSync } from 'node:fs';
import path from 'node:path';

const API = 'https://api.github.com';
const WORKFLOW_FILE = 'build-ipa.yml';
const ARTIFACT_NAME = 'Head3DCapture-IPA';

const args = process.argv.slice(2);
const flag = (n) => args.includes(n);
const opt = (n, d) => {
  const i = args.indexOf(n);
  return i >= 0 && args[i + 1] ? args[i + 1] : d;
};

const outDir = path.resolve(opt('--out', 'artifacts'));
const timeoutMin = Number(opt('--timeout', '40'));
const doDispatch = flag('--dispatch');

function sh(cmd) {
  return execSync(cmd, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
}

function repoFromOrigin() {
  const url = sh('git remote get-url origin');
  const m = url.match(/github\.com[:/]([^/]+)\/([^/.]+)/);
  if (!m) throw new Error(`Cannot parse GitHub repo from origin url: ${url}`);
  return { owner: m[1], repo: m[2] };
}

function tokenFromGit() {
  const input = 'protocol=https\nhost=github.com\n\n';
  const out = execSync('git credential fill', { input, encoding: 'utf8' });
  const line = out.split(/\r?\n/).find((l) => l.startsWith('password='));
  if (!line) throw new Error('No credential found for github.com');
  return line.slice('password='.length);
}

const { owner, repo } = repoFromOrigin();
const token = process.env.GITHUB_TOKEN || tokenFromGit();
const slug = `${owner}/${repo}`;

const headers = {
  Authorization: `Bearer ${token}`,
  Accept: 'application/vnd.github+json',
  'X-GitHub-Api-Version': '2022-11-28',
  'User-Agent': 'head3d-fetch-ipa',
};

async function api(url, init = {}) {
  const res = await fetch(url.startsWith('http') ? url : API + url, {
    ...init,
    headers: { ...headers, ...(init.headers || {}) },
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* non-json */ }
  if (!res.ok) {
    const msg = json?.message || text.slice(0, 300);
    throw new Error(`GitHub API ${res.status} ${url}: ${msg}`);
  }
  return json;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function currentBranch() {
  try { return sh('git rev-parse --abbrev-ref HEAD'); } catch { return 'master'; }
}

async function dispatchRun() {
  const ref = opt('--ref', await currentBranch());
  await api(`/repos/${slug}/actions/workflows/${WORKFLOW_FILE}/dispatches`, {
    method: 'POST',
    body: JSON.stringify({ ref }),
  });
  console.log(`▶ dispatched workflow_dispatch on ${slug}@${ref}`);
}

async function latestRun() {
  const data = await api(`/repos/${slug}/actions/workflows/${WORKFLOW_FILE}/runs?per_page=5`);
  if (!data.workflow_runs?.length) return null;
  return data.workflow_runs[0];
}

async function runDetail(id) {
  return api(`/repos/${slug}/actions/runs/${id}`);
}

async function main() {
  console.log(`repo: ${slug}`);

  if (doDispatch) await dispatchRun();

  let run = await latestRun();
  if (!run) {
    console.log('no run found yet — dispatching one');
    await dispatchRun();
    for (let i = 0; i < 10 && !run; i++) { await sleep(3000); run = await latestRun(); }
  }
  if (!run) throw new Error('Could not find any workflow run');

  const deadline = Date.now() + timeoutMin * 60_000;
  let last = '';
  while (Date.now() < deadline) {
    run = await runDetail(run.id);
    const line = `run #${run.run_number} ${run.status}${run.conclusion ? '/' + run.conclusion : ''}`;
    if (line !== last) { console.log('… ' + line); last = line; }
    if (run.status === 'completed') break;
    await sleep(15_000);
  }

  if (run.status !== 'completed') throw new Error(`Timed out after ${timeoutMin} min (run #${run.run_number})`);
  console.log(`run url: ${run.html_url}`);
  if (run.conclusion !== 'success') {
    throw new Error(`Run concluded "${run.conclusion}" — check the logs: ${run.html_url}`);
  }

  const { artifacts } = await api(`/repos/${slug}/actions/runs/${run.id}/artifacts`);
  const artifact = artifacts.find((a) => a.name === ARTIFACT_NAME && !a.expired);
  if (!artifact) throw new Error(`Artifact "${ARTIFACT_NAME}" not found (expired or missing)`);

  mkdirSync(outDir, { recursive: true });
  const zipPath = path.join(outDir, `Head3DCapture-${run.run_number}.zip`);

  // Resolve the signed redirect first: the blob host rejects a second auth mechanism.
  const head = await fetch(artifact.archive_download_url, { headers, redirect: 'manual' });
  const location = head.headers.get('location');
  const signed = location || artifact.archive_download_url;
  const dl = await fetch(signed, { redirect: 'follow' });
  if (!dl.ok) throw new Error(`Artifact download failed: ${dl.status}`);
  writeFileSync(zipPath, Buffer.from(await dl.arrayBuffer()));
  console.log(`⬇ artifact zip: ${zipPath}`);

  // Extract (unzip ships with Git for Windows; zip stays as a fallback).
  try {
    sh(`unzip -o -q "${zipPath}" -d "${outDir}"`);
    const ipa = path.join(outDir, 'Head3DCapture.ipa');
    if (!existsSync(ipa)) {
      const found = readdirSync(outDir).filter((f) => f.endsWith('.ipa'));
      if (!found.length) throw new Error('no .ipa inside artifact');
    }
    const finalIpa = path.join(outDir, `Head3DCapture-r${run.run_number}.ipa`);
    copyFileSync(path.join(outDir, 'Head3DCapture.ipa'), finalIpa);
    copyFileSync(finalIpa, path.join(outDir, 'Head3DCapture.ipa'));
    console.log(`✅ IPA ready: ${finalIpa}`);
  } catch (e) {
    console.warn(`⚠ could not unzip (${e.message}); download the zip manually: ${zipPath}`);
  }
}

main().catch((e) => {
  console.error('✖ ' + e.message);
  process.exit(1);
});
