// Turns a suggestion posted from the site's Contribute page (a GitHub issue) into
// records for data/kb.json. Pure functions only, so they can be tested anywhere;
// add-contribution.js does the GitHub and git work.
'use strict';

const FORM_MARK = '_Sent from the Contribute form on the site._';
const FAMILIES = ['hearing', 'attention', 'memory', 'language', 'development', 'emotion', 'control', 'motor', 'sensory', 'state', 'clinical', 'other'];
const FAMILY_LABELS = {
  'hearing & auditory processing': 'hearing', 'attention': 'attention', 'memory': 'memory', 'language': 'language',
  'development': 'development', 'emotion': 'emotion', 'cognitive control': 'control', 'motor & timing': 'motor',
  'perception & sensory processing': 'sensory', 'brain state & network dynamics': 'state', 'clinical & applied uses': 'clinical', 'other': 'other'
};
const DOMAINS = {time: 'Time (ERP)', freq: 'Frequency', phase: 'Frequency / phase'};
const SIGNAL_LABELS = {'erp': 'time', 'brain rhythm': 'freq', 'rhythm coupling': 'phase', 'time (erp)': 'time', 'frequency': 'freq', 'frequency / phase': 'phase'};
const CLAIMS = ['attributed', 'inferred', 'causal', 'hypothesis', 'debated'];
const CLAIM_LABELS = {'stated by the paper': 'attributed', 'attributed': 'attributed', 'used to infer': 'inferred', 'causal test': 'causal', 'hypothesis': 'hypothesis', 'debated': 'debated'};
const EVIDENCE = ['human-eeg', 'stimulation', 'intracranial', 'review'];
const EVIDENCE_LABELS = {'human eeg/erp': 'human-eeg', 'brain or sensory stimulation': 'stimulation', 'animal or intracranial': 'intracranial', 'review-level summary': 'review'};

const str = v => (v === null || v === undefined) ? '' : String(v).trim();
const low = v => str(v).toLowerCase();
const list = v => Array.isArray(v) ? v : [];
const slug = s => low(s).replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'x';

function isContribution(body) {
  const b = str(body);
  return /<!--\s*contribution\b/.test(b) || b.includes(FORM_MARK);
}

// Issues from the current form carry an exact copy of the form as JSON in a hidden comment.
// Older issues only have the readable "**Label:** value" lines, which are matched by name.
function parseContribution(body, kb) {
  const b = str(body);
  const block = b.match(/<!--\s*contribution\s*([\s\S]*?)-->/);
  if (block) {
    try {
      const p = JSON.parse(block[1]);
      if (p && typeof p === 'object') return normalise(p);
    } catch (e) {
      return {payload: null, problems: ['The hidden form data in this issue could not be read. Please submit the suggestion again from the Contribute page.']};
    }
  }
  if (!b.includes(FORM_MARK)) return {payload: null, problems: ['This issue was not sent from the Contribute page.']};
  const f = {};
  b.split(/\r?\n/).forEach(line => {
    const m = line.match(/^\s*\*\*(.+?):\*\*\s*(.*)$/);
    if (m) f[low(m[1])] = str(m[2]);
  });
  const p = {};
  const signal = f['eeg signal'] || '';
  if (/\(new signal\)\s*$/i.test(signal)) p.newMeasure = {name: signal.replace(/\s*\(new signal\)\s*$/i, ''), signal: SIGNAL_LABELS[low(f['signal type'])] || 'time', spec: f['how the paper specifies it'] || ''};
  else { const m = list(kb.measures).find(x => low(x.name) === low(signal)); if (m) p.measureId = m.id; else if (signal) p.newMeasure = {name: signal, signal: SIGNAL_LABELS[low(f['signal type'])] || 'time', spec: f['how the paper specifies it'] || ''}; }
  const topic = f['topic'] || '';
  if (/\(new topic\)\s*$/i.test(topic)) p.newConstruct = {name: topic.replace(/\s*\(new topic\)\s*$/i, ''), family: FAMILY_LABELS[low(f['topic area'])] || 'other'};
  else { const c = list(kb.constructs).find(x => low(x.name) === low(topic)); if (c) p.constructId = c.id; else if (topic) p.newConstruct = {name: topic, family: FAMILY_LABELS[low(f['topic area'])] || 'other'}; }
  const paper = f['paper'] || '';
  const src = list(kb.sources).find(x => low(x.cite) === low(paper));
  if (src) p.sourceId = src.id;
  else if (paper) {
    const tail = paper.match(/\s+((?:https?:\/\/|doi:\s*|10\.\d{4,}\/)\S+)\s*$/i);
    p.reference = tail ? {cite: paper.slice(0, tail.index).trim(), doi: tail[1].replace(/^doi:\s*/i, '')} : {cite: paper, doi: ''};
  }
  p.pages = f['pages'] || '';
  p.claim = f['what the paper says (paraphrase)'] || '';
  p.claimType = CLAIM_LABELS[low(f['link strength'])] || 'attributed';
  p.evidence = EVIDENCE_LABELS[low(f['kind of evidence'])] || 'human-eeg';
  p.paradigm = f['task'] || '';
  p.population = f['participants'] || '';
  p.behaviour = f['behavioural outcome'] || '';
  p.cites = f['original studies the paper cites'] || '';
  return normalise(p);
}

function normalise(p) {
  const out = {
    measureId: str(p.measureId) || null,
    newMeasure: p.newMeasure && str(p.newMeasure.name) ? {name: str(p.newMeasure.name), signal: DOMAINS[p.newMeasure.signal] ? p.newMeasure.signal : 'time', spec: str(p.newMeasure.spec)} : null,
    constructId: str(p.constructId) || null,
    newConstruct: p.newConstruct && str(p.newConstruct.name) ? {name: str(p.newConstruct.name), family: FAMILIES.includes(p.newConstruct.family) ? p.newConstruct.family : 'other'} : null,
    sourceId: str(p.sourceId) || null,
    reference: p.reference && str(p.reference.cite) ? {cite: str(p.reference.cite), doi: str(p.reference.doi)} : null,
    pages: str(p.pages), claim: str(p.claim),
    claimType: CLAIMS.includes(p.claimType) ? p.claimType : 'attributed',
    evidence: EVIDENCE.includes(p.evidence) ? p.evidence : 'human-eeg',
    paradigm: str(p.paradigm), population: str(p.population), behaviour: str(p.behaviour), cites: str(p.cites),
    sites: list(p.sites).map(str).filter(s => /^[A-Z][A-Za-z]{0,2}(z|\d{1,2})$/.test(s)).filter((s, i, a) => a.indexOf(s) === i).slice(0, 30),
    sitesNote: str(p.sitesNote).slice(0, 200),
    bands: list(p.bands).slice(0, 1).filter(b => b && isFinite(b.lo) && isFinite(b.hi) && Number(b.lo) >= 0 && Number(b.lo) < Number(b.hi) && Number(b.hi) <= 1000)
      .map(b => ({lo: Number(b.lo), hi: Number(b.hi), label: str(b.label).slice(0, 30)}))
  };
  return {payload: out, problems: []};
}

// Checks that keep incomplete or junk suggestions off the site. Each problem is written for the contributor.
function validate(p, kb) {
  const problems = [];
  const has = (col, id) => list(kb[col]).some(x => x.id === id);
  const len = (v, lo, hi) => v.length >= lo && v.length <= hi;
  if (p.measureId) { if (!has('measures', p.measureId)) problems.push('The chosen EEG signal is no longer on the site. Pick it again on the Contribute page.'); }
  else if (!p.newMeasure) problems.push('Choose an EEG signal, or name a new one.');
  else if (!len(p.newMeasure.name, 2, 140)) problems.push('The new EEG signal\'s name should be 2–140 characters.');
  if (p.constructId) { if (!has('constructs', p.constructId)) problems.push('The chosen topic is no longer on the site. Pick it again on the Contribute page.'); }
  else if (!p.newConstruct) problems.push('Choose a topic, or name a new one.');
  else if (!len(p.newConstruct.name, 2, 140)) problems.push('The new topic\'s name should be 2–140 characters.');
  if (p.sourceId) { if (!has('sources', p.sourceId)) problems.push('The chosen paper is no longer on the site. Pick it again on the Contribute page.'); }
  else if (!p.reference) problems.push('Give the paper: choose one or enter its full citation.');
  else if (!len(p.reference.cite, 15, 400)) problems.push('The citation should be the full reference (authors, year, title, journal), up to 400 characters.');
  if (!len(p.pages, 1, 40)) problems.push('Add the page number(s) where the paper says this.');
  if (!len(p.claim, 15, 700)) problems.push('Describe what the paper says in your own words (15–700 characters).');
  [['spec', p.newMeasure ? p.newMeasure.spec : ''], ['task', p.paradigm], ['participants', p.population], ['behavioural outcome', p.behaviour], ['original studies', p.cites]]
    .forEach(([name, v]) => { if (v.length > 400) problems.push('The ' + name + ' field is too long (400 characters at most).'); });
  const texty = [p.newMeasure && p.newMeasure.name, p.newMeasure && p.newMeasure.spec, p.newConstruct && p.newConstruct.name, p.pages, p.claim, p.paradigm, p.population, p.behaviour, p.cites].map(str).join(' ');
  if (/https?:\/\/|www\./i.test(texty)) problems.push('Web links are only allowed in the DOI or URL field. Please remove links from the other fields.');
  if (p.reference && p.reference.doi && !/^(10\.\d{4,}\/\S+|https?:\/\/\S+)$/i.test(p.reference.doi)) problems.push('The DOI or URL should look like 10.1234/abcd or start with https://.');
  return problems;
}

function shortCite(cite) {
  const surname = (cite.match(/^([^,(]+),/) || [])[1];
  const year = (cite.match(/\((\d{4})/) || [])[1];
  if (surname && year) return surname.trim() + (/(&| and |et al)/.test(cite) ? ' et al.' : '') + ' (' + year + ')';
  return cite.length > 48 ? cite.slice(0, 46) + '…' : cite;
}

// Builds the new records. Existing papers, signals and topics with the same name are reused.
function buildRecords(p, kb, issue, today) {
  const add = {sources: [], measures: [], constructs: [], entries: []};
  const tag = '-gh' + issue;
  const entryId = 'e-gh' + issue;
  if (list(kb.entries).some(e => e.id === entryId)) return {error: 'This suggestion is already on the site.'};
  let sid = p.sourceId;
  if (!sid) {
    const doi = low(p.reference.doi), cite = low(p.reference.cite);
    const found = list(kb.sources).find(s => (doi && low(s.doi) === doi) || low(s.cite) === cite);
    if (found) sid = found.id;
    else {
      const year = (p.reference.cite.match(/\((\d{4})/) || [])[1];
      sid = 'src-' + slug(p.reference.cite).slice(0, 24) + tag;
      add.sources.push({id: sid, order: 500, provenance: 'contributed', short: shortCite(p.reference.cite), year: year ? Number(year) : null,
        cite: p.reference.cite, title: '', venue: '', doi: p.reference.doi, type: 'Contributed reference', scope: '', note: '', issue: issue, addedAt: today});
    }
  }
  let mid = p.measureId;
  if (!mid) {
    const found = list(kb.measures).find(m => low(m.name) === low(p.newMeasure.name));
    if (found) mid = found.id;
    else {
      mid = 'm-' + slug(p.newMeasure.name) + tag;
      add.measures.push({id: mid, order: 500, provenance: 'contributed', name: p.newMeasure.name, short: '', aka: [],
        domain: DOMAINS[p.newMeasure.signal], signal: p.newMeasure.signal, spec: p.newMeasure.spec, specRefs: [{s: sid, p: p.pages}],
        window: null, windowNote: '', bands: p.bands || [], bandsNote: '', sites: p.sites || [], sitesNote: p.sitesNote || '', inferred: [], lateralized: false,
        caveats: [], methods: [], feasibility: {passive: null, infants: null, note: '', refs: []}, issue: issue, addedAt: today});
    }
  }
  let cid = p.constructId;
  if (!cid) {
    const found = list(kb.constructs).find(c => low(c.name) === low(p.newConstruct.name));
    if (found) cid = found.id;
    else {
      cid = 'c-' + slug(p.newConstruct.name) + tag;
      add.constructs.push({id: cid, family: p.newConstruct.family, provenance: 'contributed', name: p.newConstruct.name, definition: '', defRefs: [], issue: issue, addedAt: today});
    }
  }
  add.entries.push({id: entryId, measureId: mid, constructId: cid, sourceId: sid, pages: p.pages, claimType: p.claimType, evidence: p.evidence,
    claim: p.claim, paradigm: p.paradigm, population: p.population, behaviour: p.behaviour, cites: p.cites,
    provenance: 'contributed', issue: issue, addedAt: today});
  const name = (col, id, field) => { const r = add[col].concat(list(kb[col])).find(x => x.id === id); return r ? r[field] : id; };
  return {add: add, entryId: entryId, signal: name('measures', mid, 'name'), topic: name('constructs', cid, 'name'), paper: name('sources', sid, 'short'),
    created: {source: add.sources.length > 0, signal: add.measures.length > 0, topic: add.constructs.length > 0}};
}

// One record per line, in the same style as the rest of data/kb.json.
function line(v) {
  if (Array.isArray(v)) return '[' + v.map(line).join(', ') + ']';
  if (v && typeof v === 'object') return '{' + Object.keys(v).map(k => JSON.stringify(k) + ': ' + line(v[k])).join(', ') + '}';
  return JSON.stringify(v === undefined ? null : v);
}

// Appends records to the end of each collection without reformatting the rest of the file.
function insertRecords(text, add) {
  const lines = text.split(/\r?\n/);
  Object.keys(add).forEach(col => {
    const recs = add[col];
    if (!recs.length) return;
    const open = lines.findIndex(l => l.trim() === '"' + col + '": [');
    if (open < 0) throw new Error('Collection "' + col + '" not found in data/kb.json');
    let close = open + 1;
    while (close < lines.length && !/^\s*\],?\s*$/.test(lines[close])) close++;
    if (close >= lines.length) throw new Error('End of collection "' + col + '" not found in data/kb.json');
    let last = close - 1;
    while (last > open && !lines[last].trim()) last--;
    if (last > open) lines[last] = lines[last].replace(/\s*$/, '') + ',';
    lines.splice(close, 0, ...recs.map((r, i) => '    ' + line(r) + (i < recs.length - 1 ? ',' : '')));
  });
  const out = lines.join('\n');
  JSON.parse(out);
  return out;
}

const api = {FORM_MARK, isContribution, parseContribution, validate, buildRecords, insertRecords, line, shortCite};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
else if (typeof window !== 'undefined') window.Contribution = api;
