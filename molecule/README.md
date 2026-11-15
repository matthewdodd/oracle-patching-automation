# Molecule tests

The Molecule scenarios run the unmodified `oracle_database_patch.yml` end to end in RHEL-compatible containers (docker
driver). The Oracle software is fake: stub `sqlplus`, `lsnrctl`, `opatch` and `datapatch` (`shared/files/stubs/`) that
behave like the parts the playbook and its scripts rely on. The databases and listeners are real processes
(`ora_pmon_<SID>`, `ora_smon_<SID>`, `<ORACLE_HOME>/bin/tnslsnr`) started from copies of bash inside each fake home, so
`ps`, `/proc/<pid>/exe`, `home_inventory.bash`, the shutdown verification and OPatch's "active executables" check see
them exactly as they would see an Oracle instance.

| Scenario | Instance | Image | Covers |
|---|---|---|---|
| `default` | `el9-db` | AlmaLinux 9.6 | One database (CDB with a PDB and Java) patched with the canonical `oracle_common_*` inputs, next to another database on its own home that must be left alone. Re-run: already applied, so the run ends as "unneeded" without stopping anything. Re-run with a wrong checksum: refused at the download, nothing stopped, the failure report names the stage and the state left behind. |
| `el8` | `el8-db` | Rocky Linux 8.10 | One upper-case SID (non-CDB, no Java: no OJVM patch) driven with the original input names (`artifactory_repo`, `oracle_patch_cycle`, `oracle_patch_checksum`, `GROUP_NAME`, `script_permission`, `is_grid_layout` and `override_chg` as legacy strings), the default patch year, Python 3.11 on the target. Re-run: already applied. |
| `shared-home` | `el9-shared` | AlmaLinux 9.6 | Two running databases on one ORACLE_HOME. A run with only `DATABASE_NAME` in scope is refused by the shared home check before anything is stopped; the run with both in scope (`oracle_patch_databases`) stops both, patches the home once (as the database with Java, so the OJVM patch reaches the home), runs datapatch in each and starts both. Re-runs: already applied; one database alone still refused. |

`shared/prepare.yml` (used by every scenario) installs the role's own prerequisite package list for the release,
creates the OS users and groups, creates a throw-away CA and adds it to the container's system trust store, builds the
stub patch bundle and its `.sha256` file (`shared/files/build_patch_bundle.bash`) and serves them over https on
127.0.0.1 inside the container (`shared/files/https_repository.py`). The download therefore runs with the secure
defaults unchanged: TLS certificate verified, https only, and the required checksum given as
`sha256:<https URL of the checksum file>`. It then creates the fake homes and databases (`shared/tasks/`) and starts
the databases and their listeners. ServiceNow is not reached (`override_chg` true) and no Teams webhook is set (every
notification is skipped with a message, which never fails a run).

Each `verify.yml` checks, per host:

- every Oracle home: the Release Update (and the OJVM patch when a database in scope has Java) in `opatch lspatches`,
  OPatch upgraded from the bundle and the previous OPatch kept (`OPatch.bak.<timestamp>`); homes out of scope untouched;
- every database: its SQL patch registry, that the playbook stopped it before the patch, that datapatch ran in an
  instance started in upgrade mode and that it was started normally afterwards with its listeners and PDBs (READ
  WRITE), its alert log rotated; databases out of scope never stopped;
- the run's staging and script directories removed and its working (log) directory kept (database owner, 0750), the
  database owner in the automation group, and the bundle and its checksum file fetched over https (repository access
  log);
- re-runs (nested `ansible-playbook` with the scenario's inventory and configuration): the outcome, and that the
  instance and listener processes (same pids), the patches, OPatch and every database's SQL patch registry and
  history are unchanged. These replace Molecule's built-in `idempotence` step: every run creates its own per-run
  working directory, so a correct re-run never reports `changed=0`.

Run from the repository root, with Docker and rsync available:

```sh
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-test.txt
molecule test                               # default scenario: create, prepare, converge, verify, destroy
molecule test --scenario-name shared-home   # one scenario
molecule test --all                         # every scenario
molecule converge && molecule verify        # keep the container for debugging; molecule destroy afterwards
```

CI runs every scenario on every pull request and on push to master (`.github/workflows/molecule.yml`, one job per
scenario, "scenario (<name>)"); the job `molecule` succeeds only when every scenario succeeded and is the check that
branch protection requires.

Not covered: AIX (no container image; `lslpp`, `chgrpmem` and the 12.1 `qopiprep` fix are tested only by reading and by
the controller-side tests in `tests/`), real Oracle software (SQL*Plus output, OPatch and datapatch behaviour come
from the stubs), the Grid layout, ServiceNow and the Teams post itself.
