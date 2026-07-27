# CLAUDE.md — daneel operating rules

This file is read automatically at the start of every Claude Code session.
It mirrors the rules defined in `.agent.yml` and `.daneel.yml` so they apply
without any external Space instructions. If `.agent.yml` and this file ever
disagree, `.agent.yml` is the source of truth — update this file to match.

## First actions every session

1. Read `.agent.yml` (AI operational manifest).
2. Read `.daneel.yml` (operator profile, language, timezone).
3. Read the scenario catalog `frameworks/daneel/.scenarios.yml` from
   `Malstrom/zeroth` **before any reasoning**. Match every user message
   against a scenario first. If none matches, propose a new scenario to the
   user before proceeding.
4. Read the hard rules `Malstrom/zeroth:rules/agent.yml#hard_rules` — never
   override them.

## Language

- **Chat with the user: Русском** (always reply in Russion unless explicitly
  asked otherwise).
- **Client-facing documents: Russian.**
- **All file content, commits, PR/issue bodies: English.**
- **All file names and folder names: English**, `snake_case`, lowercase.

## Operator

- Name: Никита Mironenko — handle: `Nikitamir0nenk0`.
- Timezone: Europe/Moscow (UTC+3). Active regions: Russia,  Asia.
- Roles: ML engineer, DS, DA.
- Stack: Python, sclearn, catboost, pandas, pyspark.

## Work rules

- **Logs are append-only** — commit before responding.
- **Inbox files are write-once** — never edit after creation.

## Workspace access

Files live in two repos: `zeroth` = `Malstrom/zeroth`, `instance` = this repo
(`Malstrom/daneel`).

### zeroth (read-only)
- `frameworks/daneel/.scenarios.yml` — scenario catalog
- `frameworks/daneel/templates/` — templates for log, inbox, contact,
  playbook, client context

### instance (this repo)
- `.daneel.yml` — operator profile — read-only
- `.registry.yml` — cross-repo connections — read-only
- `contacts/` and `contacts/*.yml` — contact profiles — read-write
- `playbooks/` — recurring-work instructions — read-write
- `clients/*/context.yml` — static client info — read-write
- `clients/*/summary.md` — human-facing client summary — read-write
- `clients/*/inbox/*.yml` — raw incoming tasks — **write-once**
- `clients/*/output/**` — AI-generated deliverables — read-write
- `clients/*/playbooks/**` — client-specific playbook overrides — read-write
- `clients/*/log/*.yml` — immutable daily work logs — **append-only**
- `clients/*/log/*.index.yml` — monthly log index — read-write

## Cross-repo sync

`.registry.yml` is read by the post-action hook **after every state change**,
never proactively.

## Repo path resolution

`.agent.yml` refers to files as `Owner/repo:path`. Resolve them as:

- `Malstrom/zeroth:<path>` → local clone `/Users/nikita/Projects/zeroth/<path>`.
  Run `git -C /Users/nikita/Projects/zeroth pull` first if freshness matters
  (e.g. before trusting `.scenarios.yml` or `rules/agent.yml#hard_rules`).
- `Malstrom/daneel:<path>` → this repo, local clone at `/Users/igor/daneel/<path>`.

Prefer these local clones over fetching from GitHub — same content, no
network round trip. Only hit the GitHub API directly for things that
aren't files in the repo (issues, comments, PRs) — see below.

## Working with issues

Issue/task tracking for daneel lives on GitHub, repo `malstrom/daneel`.
Use the `gh` CLI (already authenticated as `Malstrom`) via Bash, e.g.:

- `gh issue list --repo malstrom/daneel`
- `gh issue create --repo malstrom/daneel --title "..." --body "..." --label "client:{slug}" --label "work:{work_type}"`
- `gh issue comment <number> --repo malstrom/daneel --body "..."`
- `gh issue close <number> --repo malstrom/daneel`

Issue bodies are written in Italian (Igor's working language). Post a
Russian translation as a **separate comment** on the same issue right
after creating it — Igor copies that translated comment into his
company's Russian-language task manager by hand.

## Built on

The [zeroth](https://github.com/Malstrom/zeroth) framework — daneel v1.
