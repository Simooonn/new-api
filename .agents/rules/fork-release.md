# Fork Release Rules

Conventions for the Simooonn/new-api fork: releases cut from `feature/ace`, and every schema change that ships in them. `AGENTS.md` defines when a task must read this file (see **Fork release rules (mandatory read gate)**). Rules use the same MUST / Do NOT wording as `AGENTS.md` and carry the same weight.

**Rollback compatibility:** Every release MUST roll back to the previous release by switching the image only. A rollback never restores the database: restoring a pre-upgrade dump discards everything written after the upgrade, so dumps are for disaster recovery only.

- The previous release MUST run correctly against a database already migrated by the new release. Between adjacent releases, migrations are additive only: new tables, new columns that are nullable or have a default, new indexes and constraints that both releases' writes satisfy, and new option keys.
- Do NOT, within one release, drop or rename a table or column, change a column's type, nullability or meaning, tighten a constraint the previous release may violate, change the format of an existing option value, or rewrite existing rows into a shape the previous release cannot read.
- A release MUST keep writing every column the previous release reads, in the form the previous release expects. A column may be dropped only in a release whose predecessor no longer reads it. Renames and type changes therefore take at least two releases: add the new column and write both, then switch reads, then drop the old column in a later release.
- New code MUST tolerate rows that lack its new columns, because rows written by the previous release after a rollback do not set them.
- Backfills may only populate new columns or tables, and MUST be idempotent.
- Verify a schema change by starting the new release on a copy of the latest production database, then starting the previous release's image against that same database and confirming it starts, logs in, and relays a request. This is in addition to the database verification required by `AGENTS.md`.

**Upstream merges:** QuantumNous/new-api does not follow the rollback rule. Before releasing a merge into `feature/ace`, list the migrations it brings (`git diff <previous release tag>..HEAD -- model/`, including `AutoMigrate` lists and `migrate*` functions). For each migration that is not additive (table rebuilds, constraint swaps, dropped or retyped columns, data rewrites), state in the release notes that rolling back across it is not supported, and run that upgrade with `BACKUP=1`. Known examples: `model/option_primary_key_migration.go` rebuilds `options` when its key is not unique; `model/token_migration.go` replaces the `tokens.key` unique constraint with a unique index.

**Release mechanics:**

- Tag on `feature/ace` as `v<latest upstream release contained in feature/ace>-ace.N`. N starts at 1 and restarts after merging a new upstream release, e.g. `v1.0.0-rc.44-ace.2` → `v1.0.0-rc.45-ace.1`.
- A tag runs `.github/workflows/fork-ghcr-image.yml` (`ghcr.io/simooonn/new-api:<tag>` and `:latest`, linux/amd64) and `.github/workflows/release.yml` (binaries). The upstream Docker Hub workflows stay disabled in the fork.
- The admin update check reads the fork's releases through the build-time `VITE_UPDATE_REPOSITORY` override. Do not replace the upstream default in code; it is a protected identifier in `AGENTS.md`.
- Upgrade production from the compose project directory with `./docker-upgrade.sh upgrade <tag>`, roll back with `./docker-upgrade.sh rollback`. The script recreates only the `new-api` service and does not back up the database unless `BACKUP=1` is set.
