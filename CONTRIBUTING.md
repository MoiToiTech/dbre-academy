# Contributing

Thank you for improving the DBRE Academy. Corrections from people who run
databases in production are the most valuable contribution there is.

## Reporting a problem

[Open an issue](https://github.com/MoiToiTech/dbre-academy/issues/new/choose) and pick the template:

- **Lab problem** — a command, scenario or check that does not behave as the
  lesson says. Include the output of `./lab doctor` and `./lab status`.
- **Content correction** — a technical claim that is wrong, outdated or
  misleading. Link the documentation that shows it.
- **Suggestion** — a missing topic or exercise.

Security issues: see [SECURITY.md](SECURITY.md); do not open a public issue.

## Changing things

1. Fork, branch, change.
2. Read [docs/authoring.md](docs/authoring.md) for the lesson and scenario
   conventions. The essentials:
   - every command a student is told to run is tagged so CI runs it;
   - every scenario has `setup`, `check`, `reset` and `solve` scripts and
     passes `labs/tests/scenario-test.sh`;
   - claims cite the MySQL 8.4 Reference Manual or the tool's own docs;
   - output samples come from the lab, not from memory.
3. Run the checks locally:

   ```bash
   labs/tests/static-checks.sh
   cd labs && ./lab up --observability
   tests/scenario-test.sh <your-scenario>
   tests/doctest.py ../courses/mysql-production-dba/<module>/*.md
   ```

4. Open a pull request. CI runs the full lab on amd64 and arm64.

Keep pull requests to one logical change. A new scenario with its lesson
text is one change; a typo fix across modules is another.

## Licensing of contributions

By contributing you agree that:

- code (everything under `labs/`, `.github/` and other scripts) is licensed
  under the [Apache License 2.0](LICENSE);
- educational content (everything under `courses/` and `docs/`) is licensed
  under [Creative Commons Attribution 4.0](LICENSE-CONTENT).

Only contribute material you wrote or have the right to license this way.
Do not paste text from vendor documentation, training material or books;
link to them instead. Never contribute real customer or employer data, logs
or schemas — the lab uses synthetic data only.

## Conduct

Be precise and be kind. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
