# EEG Construct–Measure Knowledge Base

A website that shows which EEG signals published papers link to which cognitive topics (memory, attention, hearing, language and more), how strong each link is, and the page to cite.

**Live site:** https://parsabemani.github.io/eeg-knowledge-base/

## What is in it

The content is being built up paper by paper. These counts are updated from the database once a day.

<!-- counts:start (filled in automatically by .github/scripts/refresh-data.js) -->
| Part | Count |
| --- | --- |
| Source papers | 4 |
| EEG signals | 15 (14 ERPs, 1 brain rhythm) |
| Topics | 10, in 8 areas |
| Links between a topic and a signal | 25 |
| Design and reporting guidance items | 10 |
<!-- counts:end -->

Every link names the paper and page it comes from. Claims are paraphrased, never quoted. Each link carries a strength label (causal test, stated by the paper, used to infer, hypothesis, debated) and, where it applies, an evidence label for findings that are not human scalp EEG.

Electrode sites worked out from a region name in a paper are marked "inferred". Details a paper does not give are left blank rather than guessed.

## Pages

- **Home**: search by topic or signal, or start from a topic area. A 2-minute tutorial shows new visitors around.
- **Topics** and **EEG signals**: browse the links in either direction. Each topic has a heat map of where its studies put the electrodes (the stronger the colour, the more studies), beside each study's own placement. Each signal has a measurement guide with its electrodes on a head map.
- **EEG basics**: a short primer for students new to EEG.
- **Plan a study** (under More): pick a topic, participants and task type to get ranked signals and a design checklist.
- **Source papers**, **Topic–signal map**, **Contribute**, **Data & export**, and **Admin** for admins (under More).

## Sources

<!-- sources:start (filled in automatically by .github/scripts/refresh-data.js) -->
- Aguiar, P. V., Williams, M. R., & Paul, B. T. (2025). Visual cortical responses in age-related hearing loss show evidence for compensatory neuroplasticity. GeroScience, 48(5), 6739–6756. https://doi.org/10.1007/s11357-025-02013-w
- Bakhos, D., Galvin, J., Roux, S., Lescanne, E., & Bruneau, N. (2018). Cortical Processing of Vocal and Nonvocal Sounds in Cochlear-Implanted Children: An Electrophysiological Study. Ear & Hearing, 39(1), 150–160. https://doi.org/10.1097/AUD.0000000000000475
- Campbell, J., & Sharma, A. (2016). Visual Cross-Modal Re-Organization in Children with Cochlear Implants. PLOS ONE, 11(1), e0147793. https://doi.org/10.1371/journal.pone.0147793
- Woodman, G. F. (2010). A brief introduction to the use of event-related potentials in studies of perception and attention. Attention, Perception, & Psychophysics, 72(8), 2031–2046. https://doi.org/10.3758/APP.72.8.2031
<!-- sources:end -->

The papers themselves are not included in this repository.

## Suggesting a link

Use the **Contribute** page on the site.

- **Current setup: sign-in and admin review** (see [SETUP.md](SETUP.md)). Anyone can create an account by signing in with an emailed code; admins can also send invitations. Contributors send a suggestion with its source and a claim type (page numbers are optional); pasting a DOI fills in the citation. When a paper links several EEG signals to the same topic, they are added side by side in one suggestion: admins get one email for all of them (and can accept them all at once), and the contributor gets one email once they have all been reviewed. Electrodes are marked on a head map, either at the fixed 10–20 positions or by free placement: dragged anywhere on the head (for 32- or 64-channel caps, or a spot such as between O1 and PO7), with the coordinates shown while dragging, or added by name or by coordinates. The electrodes each paper used are saved with its link. If they are far from where other studies of the topic put theirs, the form asks the contributor to double-check before sending; sent anyway, they are flagged for the admins and count in the topic's heat map like any others. Admins get an email with Accept and Reject buttons, and accepted links appear on the site immediately; each admin chooses which emails they get under Email preferences on the Admin page, and contributors who are not admins only get an email when their suggestion is accepted or rejected. Links and edits from admins and the owner skip review and go on the site straight away. Admins can also delete links (with undo), invite people, add other admins and step down from the Admin page. The records live in a Supabase database; `data/kb.json` is the backup the site falls back to if the database cannot be reached, and a daily job keeps it up to date.
- **Earlier setup, now switched off:** suggestions went in as GitHub issues and a GitHub Action ([`.github/workflows/add-contribution.yml`](.github/workflows/add-contribution.yml)) added them to `data/kb.json` without review. It is disabled in **Actions → Add contributions**. It only matters again if sign-in is switched off (by emptying the two Supabase values in `config.js`); in that case, re-enable it there.

### The GitHub automation (only when sign-in is off)

- [`.github/contributions.json`](.github/contributions.json) controls who is accepted without review: `"acceptFrom": "anyone"`, or a list of GitHub usernames such as `["ParsaBemani", "labmember"]`. Suggestions from anyone else are labelled `needs-review` and left open. `"maxPerDay"` limits how many links one person can add in 24 hours (default 10).
- Each addition is its own commit, named "Add contributed link from #N". To remove one, open that commit on GitHub and click **Revert**, or delete its line from `data/kb.json`.
- To re-check an existing issue by hand, open **Actions → Add contributions → Run workflow** and enter the issue number. Leave "Only check it" ticked to see what would be added without changing anything.

## Repository layout

| Path | What it is |
| --- | --- |
| `index.html` | The whole site: one page with its styles and script inline |
| `config.js` | Site settings, including the Supabase URL and public key once sign-in is set up |
| `data/kb.json` | Starter records: `meta`, `sources`, `guidance`, `measures`, `constructs`, `entries` |
| `supabase/setup.sql` | Database, sign-in roles and email approvals; run once in Supabase |
| `SETUP.md` | Step-by-step setup for sign-in, admins and email approvals |
| `.nojekyll` | Tells GitHub Pages to serve the files as they are |
| `.github/` | Automation: the daily data refresh, which also updates the counts and sources in this README, and the switched-off GitHub-issue contribution workflow |

Without sign-in, update the site by editing `data/kb.json`. Each entry links one `measureId` to one `constructId` and cites a `sourceId` with `pages`. With sign-in, the database holds the records and `data/kb.json` is a daily copy the site falls back to if the database is unreachable.
