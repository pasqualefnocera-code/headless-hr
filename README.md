# headless-hr

A headless HR platform for the full employment lifecycle.

## Status

**Prototype in progress. No production software exists.**

This repo holds a local prototype built to validate the core architecture for the founder's own
proof of concept. It is not a product, has no users, and has not been validated with buyers.

## Ground rules

- **Synthetic data only.** Never put real employee or candidate information in this repo.
- **No secrets in git.** Credentials and keys live in a local `.env` file, which is git-ignored.
- **Runs locally.** Nothing is deployed. Hosting is revisited only when the prototype is shown to others.
- **Not HR, legal, payroll, tax, or security advice.** Nothing here has been audited.

## Planned prototype scope (proposal, not built)

- Bitemporal person, job assignment, and org position records (valid time plus recorded time)
- One authorization check that every human and agent action passes through
- An append-only audit log
- One approval workflow
- A scripted agent acting through the same API and permission check as a human
