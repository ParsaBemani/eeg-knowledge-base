// Run by .github/workflows/add-contribution.yml through actions/github-script.
// Reads a suggestion issue, checks it, adds it to data/kb.json, pushes, and replies on the issue.
'use strict';
const fs = require('fs');
const path = require('path');
const {execFileSync} = require('child_process');
const C = require('./contribution.js');

const ROOT = process.cwd();
const DATA = path.join(ROOT, 'data', 'kb.json');
const SETTINGS = path.join(ROOT, '.github', 'contributions.json');
const ACCEPTED = 'auto-accepted', NEEDS_FIX = 'needs-fix', HELD = 'needs-review';

const git = (...args) => execFileSync('git', args, {cwd: ROOT, stdio: 'pipe'}).toString().trim();
const quiet = s => String(s || '').replace(/@/g, '@​');  // no accidental @mentions in replies

module.exports = async function run({github, context, core, issueNumber, dryRun}) {
  const {owner, repo} = context.repo;
  const num = issueNumber || (context.payload.issue && context.payload.issue.number);
  if (!num) { core.setFailed('No issue number.'); return; }
  const issue = (await github.rest.issues.get({owner, repo, issue_number: num})).data;
  const labels = (issue.labels || []).map(l => typeof l === 'string' ? l : l.name);
  if (issue.pull_request) { core.info('Pull request, not a suggestion.'); return; }
  if (labels.includes(ACCEPTED)) { core.info('Already added to the site.'); return; }
  if (!C.isContribution(issue.body)) { core.info('Not sent from the Contribute page; leaving it alone.'); return; }

  const settings = Object.assign({acceptFrom: 'anyone', maxPerDay: 10, siteUrl: ''}, fs.existsSync(SETTINGS) ? JSON.parse(fs.readFileSync(SETTINGS, 'utf8')) : {});
  const author = issue.user && issue.user.login;
  const reply = async body => { if (!dryRun) await github.rest.issues.createComment({owner, repo, issue_number: num, body}); };
  const label = async (add, remove) => {
    if (dryRun) return;
    if (add) await github.rest.issues.addLabels({owner, repo, issue_number: num, labels: [add]});
    for (const r of remove || []) { if (labels.includes(r)) { try { await github.rest.issues.removeLabel({owner, repo, issue_number: num, name: r}); } catch (e) {} } }
  };

  // Who may add links without review, and how many a day.
  if (settings.acceptFrom !== 'anyone' && !(Array.isArray(settings.acceptFrom) && settings.acceptFrom.includes(author))) {
    core.info(author + ' is not on the acceptFrom list; holding for review.');
    if (!labels.includes(HELD)) {
      await reply('Thanks for the suggestion! It has been received and is waiting for a maintainer to review it.');
      await label(HELD);
    }
    return;
  }
  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const recent = await github.paginate(github.rest.issues.listForRepo, {owner, repo, creator: author, labels: ACCEPTED, state: 'all', since, per_page: 100});
  const today = recent.filter(i => i.closed_at && i.closed_at >= since).length;
  if (today >= settings.maxPerDay) {
    core.info(author + ' reached the daily limit (' + settings.maxPerDay + ').');
    if (!labels.includes(HELD)) {
      await reply('Thanks! You have added ' + today + ' links in the last 24 hours, which is the daily limit, so this one is waiting for a maintainer.');
      await label(HELD);
    }
    return;
  }

  const text = fs.readFileSync(DATA, 'utf8');
  const kb = JSON.parse(text);
  const parsed = C.parseContribution(issue.body, kb);
  const problems = parsed.payload ? C.validate(parsed.payload, kb) : parsed.problems;
  if (problems.length) {
    core.info('Problems:\n- ' + problems.join('\n- '));
    if (dryRun) { core.summary.addHeading('Would ask for fixes').addList(problems).write(); return; }
    await reply('Thanks for the suggestion! Before it can be added, please fix the following by editing this issue (the **⋯** menu → **Edit**). It will be checked again automatically when you save.\n\n'
      + problems.map(p => '- ' + quiet(p)).join('\n'));
    await label(NEEDS_FIX);
    return;
  }

  const date = new Date().toISOString().slice(0, 10);
  const built = C.buildRecords(parsed.payload, kb, num, date);
  if (built.error) {
    core.info(built.error);
    if (!dryRun) { await label(ACCEPTED, [NEEDS_FIX, HELD]); await github.rest.issues.update({owner, repo, issue_number: num, state: 'closed', state_reason: 'completed'}); }
    return;
  }
  const out = C.insertRecords(text, built.add);
  const summary = built.signal + ' → ' + built.topic;
  core.info('Adding: ' + summary + ' (' + built.paper + ')');
  if (dryRun) {
    core.summary.addHeading('Would add: ' + summary)
      .addCodeBlock(Object.keys(built.add).flatMap(k => built.add[k].map(r => k + ': ' + C.line(r))).join('\n'), 'json').write();
    return;
  }

  fs.writeFileSync(DATA, out.endsWith('\n') || !text.endsWith('\n') ? out : out + '\n');
  git('config', 'user.name', 'github-actions[bot]');
  git('config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com');
  git('add', 'data/kb.json');
  git('commit', '-m', 'Add contributed link from #' + num + ': ' + summary.slice(0, 120));
  git('push');

  // Ask GitHub Pages to rebuild now (it usually does on its own; this is a backstop).
  try { await github.request('POST /repos/{owner}/{repo}/pages/builds', {owner, repo}); } catch (e) { core.info('Pages rebuild request: ' + e.message); }

  const created = [built.created.signal && 'a new signal', built.created.topic && 'a new topic', built.created.source && 'a new paper'].filter(Boolean);
  await reply('Thanks! Your link **' + quiet(summary) + '** has been added to the site'
    + (created.length ? ', along with ' + created.join(' and ') : '') + '. It appears within a couple of minutes'
    + (settings.siteUrl ? ': ' + settings.siteUrl : '') + '.');
  await label(ACCEPTED, [NEEDS_FIX, HELD]);
  await github.rest.issues.update({owner, repo, issue_number: num, state: 'closed', state_reason: 'completed'});
};
