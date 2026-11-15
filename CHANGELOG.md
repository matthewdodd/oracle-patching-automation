# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The project intends to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) from its first tagged release.

## [Unreleased]

The production-readiness rework of the original playbooks. They run on a supported ansible-core, refuse to patch an
Oracle home other databases still use, have no environment-specific values in code, and are secure by default. The
job inputs of existing AAP job templates (`target`, `DATABASE_NAME`, `TICKET_NUMBER`, `override_chg`,
`sid_server_dict`, `artifactory_repo`, `GROUP_NAME`, `is_grid_layout`, ...) keep working; see README.md "AAP usage
and migrating existing job templates".

### Breaking changes and upgrade notes

- **ansible-core 2.22** is required on the controller (Python 3.13 or later); targets need Python 3.9 or later.
  The original playbooks used syntax that current ansible-core rejects (`include:`, list-form task `vars`, the
  removed `yaml` callback, `callback_whitelist`, `auto_legacy_silent`).
- **EL7 and Amazon Linux 2 are refused** by an early guard that names the actual distribution and version, before
  anything changes on the host (no vendor Python 3.9+).
- **New required input: the patch checksum** `oracle_common_patch_checksum` (alias `oracle_patch_checksum`),
  `<algorithm>:<hex digest>` or `<algorithm>:<https URL>`; the download is verified against it.
- **Repository URL**: `artifactory_repo` is still accepted (and still names the release folder); the new
  `oracle_common_patch_repo_url` gets the release folder appended. https is required (opt-in
  `oracle_common_patch_repo_allow_http`).
- **`GROUP_NAME` has no default** any more (the site group was hard-coded). It is required while
  `oracle_common_manage_group_membership` is true (default), or set that toggle to false.
- **Shared ORACLE_HOME**: a run is refused when databases outside its scope use the home. Patch them together with
  `oracle_patch_databases` (see Added).
- **No default inventory** (`ansible.cfg`): pass `-i inventory/<env>/hosts.yml`.
- **SSH host key checking is on**, and `allow_world_readable_tmpfiles` is gone: becoming the database owner needs
  the `acl` package, `ansible_common_remote_group`, or a root connection.
- **Secrets move to Ansible Vault** (one vault id per environment; AAP Vault credentials): Teams webhook
  (`vault_teams_webhook_url`), ServiceNow (`vault_snow_instance`, `vault_snow_user`, `vault_snow_password`; the
  original `snow_*` names are still accepted) and optional repository credentials.
- **Teams**: the retired Office 365 connector card is replaced by a Teams Workflows webhook; create the webhook and
  store its URL in the vault.
- **Modes**: 0777 is removed everywhere, with no toggle. Scripts 0750, directories 0750, bundle 0640, extracted
  patch `u=rwX,g=rX,o=`; `script_permission` is still accepted but group- or world-writable values are rejected.
- **Working directories** default to `<oracle_common_patch_base_dir_oracle>/ansible_patch_work` (was `/tmp`), per
  run (`_<run id>` suffix). The database owner must be able to create the base, or set `oracle_common_staging_base`.
- The bundled scripts source a `<SID>.env` file only when it is owned by the database owner or root and not
  world-writable (`oracle_common_env_file_allow_any_owner: true`, alias `oracle_patch_env_file_allow_any_owner`, also
  accepts another owner; a world-writable file is always refused).

### Behaviour changes (each with the way back where one exists)

| Change | Unit | Restore the original |
|---|---|---|
| A patch already applied in every database ends the run **successfully** with the "unneeded" card (was a failed run). | U2 | `oracle_common_fail_when_already_applied: true` (alias `oracle_patch_fail_when_already_applied`) |
| A failed status check sends the "fail" card (was "unneeded"). | U2 | none (bug fix) |
| A failed database shutdown fails the run, and the database must be verified down (was `ignore_errors`, so OPatch could run on a live home). | U2 | none (safety); the verification window is `standalone_control_role_shutdown_verify_retries` / `_delay` |
| Listener stop failures are detected (were masked by `tee`); exit code 4 (already stopped) is accepted. A stop continues with the remaining listeners. | U2, SH | none (bug fix) |
| Per-run working and staging directories; cleanup removes only what the run created. | U2 | `oracle_common_unique_work_dirs: false` (alias `oracle_patch_unique_work_dirs`); explicit `remote_script_directory` / `remote_output_directory` / `patch_folder_name` are used exactly, as before |
| Patch step timeout 14400 s (was 4000 s while polling up to 14400 s). | U2 | `oracle_common_patch_timeout: 4000` (alias `oracle_patch_apply_timeout`) |
| Working directory base under the Oracle base (was `/tmp`). | U3 | `oracle_common_staging_base: /tmp` (accepted with a warning) |
| Download TLS certificate verified (was `validate_certs: no`). | U3 | `oracle_common_patch_validate_certs: false` (warning; checksum still verified) |
| Script mode 0750 (was 0777, then 0755 in U1). | U1, U3 | `oracle_common_script_permission` / `script_permission` (any mode without group/world write) |
| Log rotation failure before a startup (rename_logs exit 4) is a WARNING and the database is started (the startup used to fail, leaving a patched database down). | U4 | `standalone_control_role_fail_on_rename_logs_error: true` |
| Alert log check log named `log.check_alert_log.bash` (was `log.check_mount.bash`, a copy-and-paste slip). | U4 | `standalone_control_role_alert_log_check_log: log.check_mount.bash` |
| An empty `dbvip` skips the VIP ping (the original ran `ping -c2` without an address and failed). | U4 | none (bug fix) |
| A startup copies its own scripts (no longer depends on an earlier shutdown in the same run). | U4 | none |
| `server_name` is the current host (was the whole `target` string, broken for several targets). | U4 | pass `server_name` explicitly |
| `override_chg` is a real boolean; a boolean `false` now runs the change check (it used to skip it) and an undefined value means `false` (it used to fail). The legacy strings are accepted. | U1N, U2 | `override_chg: true` skips the check |
| `is_grid_layout` is a real boolean; a boolean `false` now selects the Oracle layout (anything but the string `'false'` used to select Grid). | U1 | `is_grid_layout: true` |
| An unknown database version fails (was silently patched with the 12.1 artifacts). | U1 | add or override a file in `roles/oracle_common/vars/oracle_versions/` |
| The prerequisite package check covers the whole Red Hat family with a list per release (was RHEL only, with EL7-only packages that always failed on EL8/EL9). | U1 | `oracle_common_check_packages: false` |
| Group membership is checked exactly (was a substring match) and changed through `become` (was raw `sudo` in a shell); the become method comes from the inventory. | U3 | `oracle_common_manage_group_membership: false` to skip it |
| The repository sanity check compares the release folder with the detected version (was a fixed-offset string slice). | U1 | `oracle_common_patch_repo_version_check: false` |
| Teams cards are posted from localhost by default (the prerequisite playbook's target-play cards ran on the database host). | U1N | `oracle_common_notify_delegate_to: ""` |
| A notification failure never fails the run (the start card used to abort the run). | U1N | none |
| OPatch "succeeded" is accepted on AIX too (only "completed with warnings" was). | SH | none (bug fix) |
| An unknown `database_patch.bash` mode exits 64 (was 0). | SH | none (bug fix) |
| The scripts source a `<SID>.env` only when it is owned by the database owner or root (any owner used to be sourced); a world-writable file is refused. | SH, U2 | `oracle_common_env_file_allow_any_owner: true` (alias `oracle_patch_env_file_allow_any_owner`; the strings `"true"` / `"false"` are accepted) for another owner; no way back for a world-writable file |
| The control scripts in a patch run source the environment file of the SID as given (`<env dir>/<SID>.env`, the file `database_patch.bash` always used) instead of `/local/<lower-case SID>.env`; identical for lower-case SIDs. | U2 | name the files in lower case, or set `oracle_common_env_file` |

### Added

- **U0**: pinned toolchain (`requirements.txt`: ansible-core 2.22.0, ansible-lint 26.11.0, yamllint 1.38.0,
  shellcheck-py 0.11.0.1) and collections (`collections/requirements.yml`); `.yamllint`, `.ansible-lint` (production
  profile, no skips); GitHub Actions `lint` job (yamllint, shellcheck, syntax checks, ansible-lint; actions pinned to
  commit SHAs); `inventory/example/`; an early assert for `target`.
- **U1**: role `oracle_common` with one defaults file per concern, layered OS variables (`vars/<system>.yml`,
  `<os_family>.yml`, `<distribution>.yml`, `<os_family>-<major>.yml`, `<distribution>-<major>.yml`; RHEL 8/9/10 and
  AIX), one file per Oracle version (12.1, 12.2, 19, **23ai, 26ai**; selected by `v$instance.version_full` when
  the database reports it, so 26ai is told apart from 23ai, else by `v$instance.version`; `db_ver` unchanged) with
  per-environment overrides (`oracle_common_oracle_version_overrides`) and explicit selection (`oracle_common_db_version` /
  `oracle_patch_db_version`), the EL7 / Amazon Linux 2 guard, strict input validation (anchored `\A..\Z` patterns,
  one `..` path rule, `'%04o'` mode normalisation, exact checksum format, `"<CHANGE_ME>"` rejected), configurable
  patch cycle, year and file name (`oracle_patch_cycle`, `oracle_patch_year`, `oracle_patch_file_name`), configurable
  staging layout, and `meta/argument_specs.yml` + `meta/main.yml` for every role.
- **U1N**: Teams Workflows notification (Adaptive Card through `ansible.builtin.uri`, `no_log`, best effort; every
  original state, text and fact kept; `awx_*` job variables with the `tower_*` names as aliases and CLI defaults;
  optional AAP job link `aap_base_url` and path); ServiceNow check on `servicenow.itsm.change_request_info` with a
  configurable allowed state range (default -2 .. -1), optional proxy and clear messages for no / several records.
- **SH**: function-based, validated, shellcheck-clean scripts; `database_patch.bash` modes `apply_home` and
  `datapatch` (`apply` = both), per-patch OPatch status files, OPatch upgrade with a kept backup
  (`oracle_patch_opatch_backup_dir`); new read-only `home_inventory.bash`; `tests/shell` (stubbed Oracle tools, a
  runner and mutation tests).
- **U2**: shared ORACLE_HOME detection and refusal before anything is stopped; multi-database runs on one home
  (`oracle_patch_databases`: stop all, apply the home once, datapatch per database, start all); opt-in
  `oracle_patch_allow_shared_home_partial` for stopped out-of-scope databases; shutdown verification; exact
  database owner check; per-run working directories; configurable patch timeout and polling;
  `oracle_common_env_file_allow_any_owner` (alias `oracle_patch_env_file_allow_any_owner`) passes
  `ORA_ENV_FILE_ALLOW_ANY_OWNER=true` to every bundled script, patch and start/stop alike.
- **U3**: required checksum and TLS on the download, optional CA bundle, proxy and Vault repository credentials
  (`vault_patch_repo_username` / `vault_patch_repo_password`); `oracle_common_dir_mode`, `oracle_common_file_mode`,
  `oracle_common_work_group`, `oracle_common_group_membership_become_user`; PATH clean-up after sourcing an
  environment file.
- **U4**: failure report at the end of every rescue (stage, task, error, exit code, last output lines, and the state
  left behind: databases stopped, Oracle home patched / unchanged / unknown, datapatch per database, files kept or
  removed; `oracle_common_failure_msg_max_length`, `oracle_common_failure_output_lines`); toggles
  `standalone_control_role_fail_on_alert_log_errors` and `_fail_on_listener_log_errors` (default false: WARNING, as
  before); controller-only regression tests under `tests/`.
- **U7**: README (usage, variable reference with aliases, shared home, already applied, Vault, Teams, ServiceNow,
  AAP migration, troubleshooting, testing), this changelog, `LICENSE` (GPL-3.0 text) and `NOTICE`
  (GPL-3.0-or-later with the carve-out for Oracle, Red Hat and IBM software), and the `inventory/dev`, `test` and
  `prod` skeletons (`"<CHANGE_ME>"` placeholders that fail validation, wired `vault_*` mappings,
  `vault.yml.example` per environment, `inventory/README.md`).

- **U8**: CI (`lint` job) rejects a committed vault file without the `$ANSIBLE_VAULT;` header (`*.example` exempt),
  shellchecks the script tests and the Molecule fixture, and runs every `tests/*.yml` playbook and
  `tests/shell/run.bash`; the Molecule workflow ends with one `molecule` job that sums up the scenario jobs (the
  required check); `.github/dependabot.yml` for the GitHub Actions SHA pins and the pip tooling pins;
  `tests/download.yml` downloads from an https repository with a private CA.

### Changed

- Variables moved from role `vars/` (only `-e` could override them) to `defaults/`, so the inventory can set them;
  every original name is kept as an alias: `artifactory_repo`, `GROUP_NAME`, `script_permission`,
  `remote_script_directory`, `remote_output_directory`, `is_grid_layout`, `patch_folder_prefix`, `b_user`,
  `patch_folder_name`, `patch_file_name`, `timeToPause`, `remote_*_directory_base`, the standalone script-name
  variables (`check_alertLog_script`, `start_database_script`, ...), `snow_instance`, `snow_user`, `snow_password`,
  `override_chg`, `tower_*`.
- Commands run with `ansible.builtin.command` argv and values passed through the environment (no `shell` module, no
  raw `sudo`, no hard-coded `become_method`); FQCN everywhere; ansible-lint production profile clean.
- `ignore_errors` is gone; warning-only behaviours (alert log and listener log checks) are explicit WARNING tasks.
- Script copy sources use `role_path`, so the playbooks work from any directory (e.g. an AAP project subdirectory).
- `oracle_common_patch_ca_path` reaches the download as `SSL_CERT_FILE` (the CA bundle is trusted in addition to
  the system trust store): `ansible.builtin.get_url` has no `ca_path` option, so setting it used to fail the run with
  "Unsupported parameters".
- `inventory/example/group_vars/all/oracle_common.yml` writes the required values as
  `"{{ <original name> | default('<CHANGE_ME>') }}"` like the environment skeletons, so `artifactory_repo`,
  `oracle_patch_checksum` and `GROUP_NAME` keep working with it, and shows the current defaults (work base
  `<base_dir_oracle>/ansible_patch_work`, script mode `0750`); its `vault.yml.example` lists the repository
  credentials and states that a `"<CHANGE_ME>"` webhook refuses the run.

### Removed

- Support for EL7 / RHEL 7 and older and Amazon Linux 2.
- 0777 modes (no toggle).
- `community.general` (`office_365_connector_card`) and `servicenow.servicenow` (`snow_record_find`).
- Hard-coded environment values: the Office 365 webhook placeholder, `ansibletower.domain.com`, `proxy-url` /
  `proxy` proxies, `artifactory.domain.com`, the site group `ansibleUserGroup`.
- The unused `lookup("file", "vars_vault.yml")` (`listed`).

### Security

- Secrets only in Ansible Vault, `no_log` on every task that handles one; TLS verification and required checksums;
  strict anchored input validation; least-privilege modes; no shell injection; `become` instead of `sudo`; SSH host
  key checking on; no world-readable temporary files.

### Known open items (owner)

- 23ai / 26ai defaults are unverified: the version is selected by `v$instance.version_full` when reported (23.26 and
  later selects 26ai, earlier 23.x selects 23ai; without version_full a 23.0.0.0.0 database is treated as 23ai);
  repository folders, README patterns and datapatch mode to confirm.
- Script-only toggles not yet exposed by the playbooks: `ORA_OPATCH_UPGRADE`, `ORA_STATUS_STARTUP` (prerequisite-only
  runs still upgrade OPatch, run utlrp and start a database that is not open, as before),
  `ORA_FAIL_ON_NEW_INVALID_OBJECTS`, explicit patch ids.
- The prerequisite playbook still sends the "patching" cards (the `prereq` states exist but are unused, as before).
- Real-host validation on RHEL 8/9/10 and AIX, and the Molecule scenarios in CI.
