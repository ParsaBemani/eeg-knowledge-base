// Run by .github/workflows/refresh-data.yml through actions/github-script.
// Reads every record from the live database (address and public key from config.js) and rewrites
// data/kb.json in the same layout, one record per line, committing only when something changed.
'use strict';
const fs = require('fs');
const path = require('path');
const {execFileSync} = require('child_process');

const ROOT = process.cwd();
const DATA = path.join(ROOT, 'data', 'kb.json');
const STAMP = path.join(ROOT, '.github', 'last-data-check.txt');
const ORDER = ['meta', 'sources', 'guidance', 'measures', 'constructs', 'entries'];
const QUIET_DAYS = 30;

const git = (...args) => execFileSync('git', args, {cwd: ROOT, stdio: 'pipe'}).toString().trim();

module.exports = async function run({github, context, core}) {
  const cfg = fs.readFileSync(path.join(ROOT, 'config.js'), 'utf8');
  const url = (cfg.match(/supabaseUrl:\s*'([^']+)'/) || [])[1];
  const key = (cfg.match(/supabaseAnonKey:\s*'([^']+)'/) || [])[1];
  if (!url || !key) { core.setFailed('config.js has no database address or key, so there is nothing to refresh.'); return; }

  let rows;
  try {
    const res = await fetch(url.replace(/\/$/, '') + '/rest/v1/kb_records?select=collection,id,doc::text&order=collection,id',
      {headers: {apikey: key, Authorization: 'Bearer ' + key}});
    if (!res.ok) throw new Error('HTTP ' + res.status);
    rows = await res.json();
  } catch (e) {
    core.setFailed('The database did not answer (' + e.message + '). If the Supabase project is paused, restore it from the Supabase dashboard. data/kb.json was left as it is.');
    return;
  }
  // Never replace the saved copy with an empty or broken one.
  const count = col => Array.isArray(rows) ? rows.filter(r => r.collection === col).length : 0;
  if (!count('measures') || !count('sources')) {
    core.setFailed('The database returned no signals or papers, so data/kb.json was left as it is.');
    return;
  }

  const cols = ORDER.concat([...new Set(rows.map(r => r.collection))].filter(c => !ORDER.includes(c)).sort());
  const block = col => '  "' + col + '": [\n' + rows.filter(r => r.collection === col).map(r => {
    const doc = String(r.doc).trim();
    return '    {"id": ' + JSON.stringify(r.id) + (doc === '{}' ? '}' : ', ' + doc.slice(1));
  }).join(',\n') + '\n  ]';
  const text = '{\n' + cols.map(block).join(',\n\n') + '\n}\n';
  const before = fs.existsSync(DATA) ? fs.readFileSync(DATA, 'utf8').replace(/\r\n/g, '\n') : '';

  git('config', 'user.name', 'github-actions[bot]');
  git('config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com');
  if (before !== text) {
    fs.writeFileSync(DATA, text);
    git('add', 'data/kb.json');
    git('commit', '-m', 'Refresh the saved copy of the data (' + rows.length + ' records)');
    git('push');
    // Pushes made with the workflow's token do not start a Pages build on their own.
    try { await github.request('POST /repos/{owner}/{repo}/pages/builds', context.repo); } catch (e) { core.info('Pages rebuild request: ' + e.message); }
    core.info('Read ' + rows.length + ' records; data/kb.json updated.');
    return;
  }
  core.info('Read ' + rows.length + ' records; data/kb.json is already up to date.');

  // GitHub switches off scheduled workflows in a repository with no activity for 60 days.
  // If nothing has been committed for a month, note the date of this check so the schedule stays on.
  const last = Number(git('log', '-1', '--format=%ct')) * 1000;
  if (Date.now() - last > QUIET_DAYS * 86400000) {
    const today = new Date().toISOString().slice(0, 10);
    fs.writeFileSync(STAMP, 'The daily data refresh last checked the database on ' + today + '.\n' +
      'It writes this file only after a quiet month, so GitHub keeps the daily schedule switched on.\n');
    git('add', path.relative(ROOT, STAMP));
    git('commit', '-m', 'Daily data check: nothing changed this month (' + today + ')');
    git('push');
    core.info('No commits for ' + QUIET_DAYS + ' days; recorded this check to keep the schedule on.');
  }
};
