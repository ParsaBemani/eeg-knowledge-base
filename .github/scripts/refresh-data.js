// Run by .github/workflows/refresh-data.yml through actions/github-script.
// Reads every record from the live database (address and public key from config.js) and rewrites
// data/kb.json in the same layout, one record per line, committing only when something changed.
// It also rebuilds the counts table and the list of papers in README.md from the same records.
'use strict';
const fs = require('fs');
const path = require('path');
const {execFileSync} = require('child_process');

const ROOT = process.cwd();
const DATA = path.join(ROOT, 'data', 'kb.json');
const README = path.join(ROOT, 'README.md');
const STAMP = path.join(ROOT, '.github', 'last-data-check.txt');
const ORDER = ['meta', 'sources', 'guidance', 'measures', 'constructs', 'entries'];
const QUIET_DAYS = 30;
// The site's signal kinds and topic areas (SIG and FAMILIES in index.html), used for the README counts.
const SIGNALS = [['time', 'ERP', 'ERPs'], ['freq', 'brain rhythm', 'brain rhythms'],
  ['phase', 'rhythm-coupling measure', 'rhythm-coupling measures'], ['stage', 'sleep-scoring measure', 'sleep-scoring measures']];
const AREAS = ['hearing', 'attention', 'memory', 'language', 'development', 'emotion', 'control', 'motor', 'sensory', 'state', 'clinical', 'other'];

const git = (...args) => execFileSync('git', args, {cwd: ROOT, stdio: 'pipe'}).toString().trim();
const plural = (n, one, many) => n + ' ' + (n === 1 ? one : many);

// The README's counts table and list of papers, built from the database rows.
function readmeParts(rows) {
  const of = col => rows.filter(r => r.collection === col).map(r => JSON.parse(r.doc));
  const measures = of('measures'), constructs = of('constructs'), sources = of('sources');
  const sigOf = m => SIGNALS.some(s => s[0] === m.signal) ? m.signal : 'time';
  const kinds = SIGNALS.map(([id, one, many]) => [measures.filter(m => sigOf(m) === id).length, one, many])
    .filter(k => k[0]).map(k => plural(k[0], k[1], k[2]));
  const areas = new Set(constructs.map(c => AREAS.includes(c.family) ? c.family : 'other')).size;
  const counts = [
    '| Part | Count |',
    '| --- | --- |',
    '| Source papers | ' + sources.length + ' |',
    '| EEG signals | ' + measures.length + (kinds.length ? ' (' + kinds.join(', ') + ')' : '') + ' |',
    '| Topics | ' + constructs.length + ', in ' + plural(areas, 'area', 'areas') + ' |',
    '| Links between a topic and a signal | ' + of('entries').length + ' |',
    '| Design and reporting guidance items | ' + of('guidance').length + ' |'
  ].join('\n');
  // Citations are written by contributors: keep each on one line, and let none open an HTML tag or comment.
  const cite = s => {
    let t = String(s.cite || s.short || s.id).replace(/\s+/g, ' ').trim();
    if (s.doi && !t.includes(s.doi)) t += ' https://doi.org/' + s.doi;
    if (s.note) t += ' ' + String(s.note).replace(/\s+/g, ' ').trim();
    return '- ' + t.replace(/</g, '&lt;');
  };
  return {counts: counts, sources: sources.map(cite).sort((a, b) => a.localeCompare(b, 'en')).join('\n')};
}

// Replaces the lines between "<!-- name:start ... -->" and "<!-- name:end -->"; text without the markers is left alone.
function fill(text, name, body) {
  const re = new RegExp('(<!-- ' + name + ':start[^>]*-->\\n)[\\s\\S]*?(\\n<!-- ' + name + ':end -->)');
  return text.replace(re, (all, start, end) => start + body + end);
}

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

  // A problem with the README never stops the data refresh.
  const readmeBefore = fs.existsSync(README) ? fs.readFileSync(README, 'utf8').replace(/\r\n/g, '\n') : '';
  let readme = readmeBefore;
  try {
    const parts = readmeParts(rows);
    readme = fill(fill(readme, 'counts', parts.counts), 'sources', parts.sources);
  } catch (e) {
    core.warning('The counts in README.md were not refreshed (' + e.message + ').');
  }

  git('config', 'user.name', 'github-actions[bot]');
  git('config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com');
  const changed = [];
  if (before !== text) { fs.writeFileSync(DATA, text); changed.push('data/kb.json'); }
  if (readme !== readmeBefore) { fs.writeFileSync(README, readme); changed.push('README.md'); }
  if (changed.length) {
    const data = changed.includes('data/kb.json');
    git('add', ...changed);
    git('commit', '-m', data ? 'Refresh the saved copy of the data (' + rows.length + ' records)' : 'Refresh the counts and papers in the README');
    git('push');
    // Pushes made with the workflow's token do not start a Pages build on their own.
    if (data) { try { await github.request('POST /repos/{owner}/{repo}/pages/builds', context.repo); } catch (e) { core.info('Pages rebuild request: ' + e.message); } }
    core.info('Read ' + rows.length + ' records; updated ' + changed.join(' and ') + '.');
    return;
  }
  core.info('Read ' + rows.length + ' records; data/kb.json and README.md are already up to date.');

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
