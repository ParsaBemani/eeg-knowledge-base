# EEG Construct–Measure Knowledge Base

A website that shows which EEG signals published papers link to which cognitive topics (memory, attention, hearing, language and more), how strong each link is, and the page to cite.

**Live site:** https://parsabemani.github.io/eeg-knowledge-base/

## What is in it

| Part | Count |
| --- | --- |
| Source papers | 6 |
| EEG signals | 31 (21 ERPs, 9 brain rhythms, 1 rhythm-coupling measure) |
| Topics | 72, in 12 areas |
| Links between a topic and a signal | 99 |
| Design and reporting guidance items | 16 |

Every link names the paper and page it comes from. Claims are paraphrased, never quoted. Each link carries a strength label (causal test, stated by the paper, used to infer, hypothesis, debated) and, where it applies, an evidence label for findings that are not human scalp EEG.

Electrode sites worked out from a region name in a paper are marked "inferred". Details a paper does not give are left blank rather than guessed.

## Pages

- **Home**: search by topic or signal, or start from a topic area.
- **Topics** and **EEG signals**: browse the links in either direction.
- **Plan a study**: pick a topic, participants and task type to get ranked signals and a design checklist.
- **EEG basics**: a short primer for students new to EEG.
- **Source papers**, **Topic–signal map**, **Contribute**, **Data & export** (under More).

## Sources

- Kappenman, E. S., & Luck, S. J. (2012). ERP components: The ups and downs of brainwave recordings. In S. J. Luck & E. S. Kappenman (Eds.), *The Oxford handbook of event-related potential components* (pp. 3–30). Oxford University Press. Read from the uncorrected proof, so page numbers may differ from print.
- Woodman, G. F. (2010). A brief introduction to the use of event-related potentials in studies of perception and attention. *Attention, Perception, & Psychophysics, 72*(8), 2031–2046. https://doi.org/10.3758/APP.72.8.2031
- Beres, A. M. (2017). Time is of the essence: A review of electroencephalography (EEG) and event-related brain potentials (ERPs) in language research. *Applied Psychophysiology and Biofeedback, 42*, 247–255. https://doi.org/10.1007/s10484-017-9371-3
- Herrmann, C. S., Strüber, D., Helfrich, R. F., & Engel, A. K. (2016). EEG oscillations: From correlation to causality. *International Journal of Psychophysiology, 103*, 12–21. https://doi.org/10.1016/j.ijpsycho.2015.02.003
- Gupta, D. S., & Chen, L. (2016). Brain oscillations in perception, timing and action. *Current Opinion in Behavioral Sciences, 8*, 161–166. https://doi.org/10.1016/j.cobeha.2016.02.021
- Buzsáki, G., & Draguhn, A. (2004). Neuronal oscillations in cortical networks. *Science, 304*(5679), 1926–1929. https://doi.org/10.1126/science.1099745

The papers themselves are not included in this repository.

## Suggesting a link

Use the **Contribute** page on the site.

- **With sign-in switched on** (see [SETUP.md](SETUP.md)): contributors sign in with an emailed code and send the suggestion. Every admin gets an email with Accept and Reject buttons, and accepted links appear on the site immediately. Admins can also delete links (with undo), add other admins and step down from the Admin page.
- **Without it:** the page opens a pre-filled GitHub issue, and a curator adds accepted links to `data/kb.json` by hand.

## Repository layout

| Path | What it is |
| --- | --- |
| `index.html` | The whole site: one page with its styles and script inline |
| `config.js` | Site settings, including the Supabase URL and public key once sign-in is set up |
| `data/kb.json` | Starter records: `meta`, `sources`, `guidance`, `measures`, `constructs`, `entries` |
| `supabase/setup.sql` | Database, sign-in roles and email approvals; run once in Supabase |
| `SETUP.md` | Step-by-step setup for sign-in, admins and email approvals |
| `.nojekyll` | Tells GitHub Pages to serve the files as they are |

Without sign-in, update the site by editing `data/kb.json`. Each entry links one `measureId` to one `constructId` and cites a `sourceId` with `pages`. With sign-in, the database holds the records and `data/kb.json` is only the starting point and a fallback if the database is unreachable.
