# Provenance

This document explains where the DevWS source in this repository came from, and how the
repository is maintained. It is deliberately brief.

---

## Where this source came from

DevWS was developed and hardened **privately** before this source repository was prepared for
public distribution. That private development produced a working, security-reviewed
implementation, and this repository is its public source form.

This repository did **not** inherit that private history. Its first commit is a deliberately
curated baseline:

- the source was audited and sanitized before public distribution;
- personal identifiers, credentials, machine-specific identifiers and personal workspace
  configuration were removed;
- the shipped default configuration was replaced with a neutral starter that describes no
  one's machine;
- historical Git objects, branches and tags were **intentionally not transplanted**;
- development continues from that baseline as ordinary commits in this repository.

The result is a short, honest history: an audited baseline followed by genuine development in
this repository. Nothing here is reconstructed, replayed or invented, and no milestone was
fabricated to make the history look longer.

## What was deliberately left behind

Some things that exist in a private working repository have no place in this source repository
and were not carried over:

- internal engineering process records and working notes;
- machine-specific runtime evidence;
- personal configuration, paths and identifiers;
- private development history.

That material is not lost — it simply lives where it belongs, in the private record, rather
than in this repository.

## What is preserved

The public baseline is not a rewrite. The parts of the implementation that carry the product's
value are preserved as they were audited:

- the production architecture and source layout;
- the privileged runtime split and the security boundaries around it;
- the authenticated privileged worker transport;
- the native interop sources;
- the configuration schema and its validation rules;
- the hermetic test suite and its outcome contract.

The one functional change made for the public source baseline is the neutral default
configuration described in [docs/configuration.md](docs/configuration.md).

## Maintenance

- Development happens as normal commits in this repository.
- The documentation describes current behaviour; it is updated in the same change that
  alters that behaviour.
- Security-relevant changes are expected to explain their reasoning in the commit message.
- History in this repository is not rewritten.

## Licensing

DevWS is licensed under the **MIT License**. See [LICENSE](LICENSE).

The license applies to everything in this repository, including the audited baseline.

## Questions about provenance

If you need to understand the origin of a specific piece of code, the repository history is
the authoritative record of everything that has happened since the first commit in this
repository. Anything earlier than that first commit is outside this repository by design.
