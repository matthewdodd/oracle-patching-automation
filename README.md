# Oracle Database patching automation

Ansible automation that applies an Oracle Database Release Update (and the matching OJVM Release Update) to
standalone Oracle Database homes on RHEL and AIX hosts, run from Ansible Automation Platform (AAP / AWX / Tower) or
from the command line. It checks the change ticket in ServiceNow, posts a Teams card for every state, refuses to
patch an Oracle home that other databases still use, stops the databases and their listeners, runs OPatch and
datapatch, starts everything again, and removes only the files it created.

Two entry playbooks:

| Playbook | What it does |
|---|---|
| `oracle_database_patch.yml` | Full patch: validation, change check, prerequisite checks, shutdown, patch, startup, cleanup. |
| `oracle_database_patch_prereq.yml` | Prerequisite checks only: everything up to and including the prerequisite step, then cleanup. Nothing is stopped or patched (the status check still starts a database that is not open, as before). |

Contents: [What a run does](#what-a-run-does) - [Supported platforms](#supported-platforms) -
[Supported Oracle versions](#supported-oracle-versions) - [Requirements](#requirements) -
[Repository layout](#repository-layout) - [Quick start](#quick-start-cli) - [Job inputs](#job-inputs) -
[Variable reference](#variable-reference) - [Shared ORACLE_HOME](#shared-oracle_home) -
[Patch already applied](#patch-already-applied) - [Working directories and cleanup](#working-directories-and-cleanup) -
[Secrets with Ansible Vault](#secrets-with-ansible-vault) - [Teams notifications](#teams-notifications-teams-workflows-webhook) -
[ServiceNow change check](#servicenow-change-check) - [Security defaults](#security-defaults) -
[AAP usage and migration](#aap-usage-and-migrating-existing-job-templates) - [Failure report](#failure-report) -
[Troubleshooting](#troubleshooting) - [Testing](#testing) - [Extending](#extending) - [License](#license)

## What a run does

`oracle_database_patch.yml`, in order (every stage that can fail ends with the [failure report](#failure-report)):

1. **Add the targets** (`hosts: all,localhost`, controller only): `target` is required; each host in it (comma or
   space separated) is added to the inventory, into the groups in `ansible_inventory_groups` when set.
2. **On localhost**: validate the job inputs (`target`, `DATABASE_NAME`, `TICKET_NUMBER`, `override_chg`,
   `sid_server_dict`, anchored patterns, `"<CHANGE_ME>"` rejected) and the patch scope; send the **start** card;
   check `DATABASE_NAME` is in `sid_server_dict`; run the **ServiceNow change check** (skipped when `override_chg`
   is true).
3. **On each target** (`gather_facts: false`):
   1. `oracle_common`: refuse unsupported platforms (EL7 and older, Amazon Linux 2) from a Python-free read of the
      OS release, gather facts, load the layered OS variables and the supported Oracle versions, validate every
      input and setting.
   2. `initialization_role`: choose this run's working directories, check the prerequisite packages, check that
      `sid_server_dict[<SID>].dbowner` owns every running database in scope (`DATABASE_NAME` must be running), add
      the database owner and the patch staging owner to `oracle_common_group_name` (when managed), stage the
      scripts, detect the database version and resolve the patch bundle (file name, repository URL, staging
      directory).
   3. **Shared ORACLE_HOME check**: refuse unless every database that uses the home is in scope
      ([details](#shared-oracle_home)). Nothing has been stopped or changed yet.
   4. **Run Prereq** (`oracle_database_patch_role` `run_prereq`): download the bundle (TLS verified, checksum
      required) and extract it; for each database in scope the AIX 12.1 qopiprep fix (when the version needs it)
      and the patch status check. When there is something to patch: the OPatch upgrade from the bundle (the old
      OPatch is kept as a backup) and `opatch prereq CheckConflictAgainstOHWithDetail` once for the home, then
      `utlrp` in each database.
   5. **Already applied** in every database in scope: cleanup, the **unneeded** card, and the run ends for that
      host successfully without stopping anything ([toggle](#patch-already-applied)).
   6. **Shutdown** (`oracle_control_sid.yml` -> `standalone_control_role`, per database in scope): VIP ping
      (skipped when `dbvip` is empty), stop the PDB listener (when `pdb` is set), the listener and the database,
      then verify the database is down (no `ora_pmon_<SID>` process left).
   7. **Patch** (`oracle_database_patch_role`): one database: `database_patch.bash apply` (OPatch apply of the DB RU
      and, when the database has Java, the OJVM RU; then datapatch), as before. Several databases of one home:
      `apply_home` once, then `datapatch` in each database. Runs asynchronously, up to
      `oracle_common_patch_timeout` seconds. On failure: no cleanup and no restart (databases stay down, staging is
      kept for diagnosis), as before.
   8. **Startup** (per database): VIP ping, rotate the alert log, start the database (and open its PDBs), check the
      alert log, start the listener, check the listener logs, start the PDB listener.
   9. **Cleanup**: remove only the script and staging directories this run created (logs are kept), then the
      **success** card.

`oracle_database_patch_prereq.yml` runs steps 1 to 3.4 (the shared-home check only reports databases out of scope
as warnings there; scope errors still fail), the already-applied skip, the cleanup and the success card. It has no
ServiceNow change check (as before) and still sends the "patching" cards (as before; see
[Teams notifications](#teams-notifications-teams-workflows-webhook)).

## Supported platforms

| Platform | Status |
|---|---|
| RHEL 8, 9, 10 and Red Hat family rebuilds (Oracle Linux, Rocky Linux, AlmaLinux) | Supported. Prerequisite package list per release (`roles/oracle_common/vars/RedHat-8.yml`, `-9.yml`, `-10.yml`). The RHEL 10 list is a conservative subset, see the comment in that file. |
| IBM AIX | Supported. The fileset check is off by default (empty list, as the original never checked AIX); set `oracle_common_prereq_packages` to enable it. |
| RHEL 7 / Oracle Linux 7 and older, Amazon Linux 2 | **Refused** before anything changes on the host, by an early guard that names the actual distribution and version (ansible-core 2.22 needs Python 3.9 or later on the target, and these releases have none from the vendor). |
| Other Linux distributions | Pass the guard (kernel Linux) but have no package list (the check is skipped with a message). Not tested. Adding one is one vars file, see [Extending](#extending). |

Targets need Python 3.9 or later (RHEL 8: an AppStream Python, e.g. `python3.12`, set with
`ansible_python_interpreter`), SSH access with a known host key, `become` for the connection user, and a way to
become the unprivileged database owner (see [Security defaults](#security-defaults)). The bundled scripts run with
`/usr/bin/bash` (`oracle_common_bash_path` for the environment-file read; AIX needs bash from the AIX Toolbox).

## Supported Oracle versions

One file per version in `roles/oracle_common/vars/oracle_versions/`. The version is detected from the running
database (`database_version.bash`, `v$instance.version`) and selects the file whose `match_regex` matches; a version
that matches no file, or several, fails the run (the original silently used the 12.1 artifacts).

| Version file | Matches (detected version) | Repository folder (`artifact_dir`) | Staging component | Notes |
|---|---|---|---|---|
| `12.1` | `12.1.*` | `12.1.0.2` | `12.1` | AIX qopiprep fix; desupported (warning, still patched). |
| `12.2` | `12.2.*` | `12.2.0.1` | `12.2` | Desupported (warning, still patched). |
| `19` | `19.*` | `19.0.0` | `19.0` | |
| `23ai` | `23.0` to `23.25.*` | `23.0.0` | `23ai` | Defaults unverified, see below. |
| `26ai` | `23.26.*` and later, `26.*` | `26.0.0` | `26ai` | Defaults unverified, see below. |

Every version file has the same keys: `label`, `match_regex`, `accept_regex`, `artifact_dir`, `staging_component`,
`readme_ru_pattern` and `readme_jvm_pattern` (README.html grep patterns that find the Release Update and OJVM folders
in the bundle; default `Database * Release Update` and `\- Oracle JavaVM Component`), `readme_jvm_min_matches` (2),
`qopiprep_fix`, `datapatch_startup_mode` (`upgrade`, the original behaviour for every version, or `normal`) and
`desupported`. Any value can be overridden per environment without editing the file:

```yaml
oracle_common_oracle_version_overrides:
  "26ai": {artifact_dir: "23.26.0", datapatch_startup_mode: normal}
```

**23ai and 26ai (unverified defaults).** No 23ai or 26ai host was available. Oracle AI Database 26ai is reported to
be delivered as Release Update 23.26 and later of the 23ai code line, so `v$instance.version` may report
`23.0.0.0.0` for both. The detection reads `v$instance.version` only, so **a 26ai database is detected as 23ai**
unless you set `oracle_common_db_version: 26ai` (alias `oracle_patch_db_version`) for those hosts or jobs; the
detected version must then still match the entry's `accept_regex`. The repository folders (`23.0.0`, `26.0.0`), the
README patterns (the 19c wording is assumed) and the datapatch mode are defaults to confirm on a real host and
override if needed.

## Requirements

Controller / execution environment (pinned in `requirements.txt`; install with `pip install -r requirements.txt`):

| Tool | Version |
|---|---|
| Python | 3.13 or later (developed and tested on 3.15) |
| ansible-core | 2.22.0 |
| ansible-lint | 26.11.0 (production profile) |
| yamllint | 1.38.0 |
| shellcheck-py | 0.11.0.1 |

Collections (pinned in `collections/requirements.yml`; only what the code uses):

```sh
ansible-galaxy collection install -r collections/requirements.yml -p collections
```

| Collection | Version | Used for |
|---|---|---|
| `ansible.posix` | 2.2.2 | `callbacks_enabled = ansible.posix.profile_tasks` (per-task timing) in `ansible.cfg` |
| `servicenow.itsm` | 2.17.0 | `change_request_info` (ServiceNow change check) |

The Teams notification uses `ansible.builtin.uri` (no collection). `community.general` and the retired
`servicenow.servicenow` collection are no longer needed.

## Repository layout

```
oracle_database_patch.yml          full patch playbook
oracle_database_patch_prereq.yml   prerequisite-only playbook
notification.yml                   Teams card include (call, summary_state) -> oracle_common tasks/notify.yml
oracle_chg_ticket.yml              ServiceNow change check include -> oracle_common tasks/change_ticket.yml
oracle_control_sid.yml             startup / shutdown include (control: startup | shutdown) -> standalone_control_role
ansible.cfg                        no default inventory, host key checking on, YAML output, profile_tasks, pipelining
inventory/example/                 filled-in example (example values only); used by CI and the tests
inventory/dev|test|prod/           environment skeletons with "<CHANGE_ME>" placeholders (inventory/README.md)
roles/oracle_common/               shared defaults (defaults/main/<concern>.yml), layered OS vars, Oracle version files,
                                   validation, platform guard, shared-home check, Teams, ServiceNow, failure report
roles/initialization_role/         working directories, packages, owner check, group membership, version, bundle
roles/oracle_database_patch_role/  download and prerequisite checks, patch steps, cleanup; database_patch.bash,
                                   database_version.bash, home_inventory.bash
roles/standalone_control_role/     start / stop of a database, its listener and PDB listener; control scripts
tests/                             controller-only regression playbooks and tests/shell (script tests with stubs)
LICENSE, NOTICE                    GPL-3.0-or-later, with the carve-out for Oracle, Red Hat and IBM software
CHANGELOG.md                       changes, behaviour changes and opt-in toggles
```

Every role has `meta/argument_specs.yml` (the authoritative variable reference, with aliases) and its defaults in
`defaults/`; `roles/oracle_common/defaults/main/` has one file per concern.

## Quick start (CLI)

```sh
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
ansible-galaxy collection install -r collections/requirements.yml -p collections
export ANSIBLE_COLLECTIONS_PATH="$PWD/collections"

# 1. Fill in the environment's skeleton (inventory/README.md): hosts, sid_server_dict, repository URL,
#    checksum, group (or oracle_common_manage_group_membership: false).
$EDITOR inventory/dev/hosts.yml inventory/dev/group_vars/all/main.yml inventory/dev/group_vars/all/oracle_common.yml

# 2. Secrets (Teams webhook, ServiceNow, repository credentials) in an encrypted vault file.
cp inventory/dev/group_vars/all/vault.yml.example inventory/dev/group_vars/all/vault.yml
$EDITOR inventory/dev/group_vars/all/vault.yml
ansible-vault encrypt --vault-id dev@prompt inventory/dev/group_vars/all/vault.yml

# 3. Prerequisite checks only (nothing is stopped or patched).
ansible-playbook -i inventory/dev/hosts.yml --vault-id dev@prompt oracle_database_patch_prereq.yml \
  -e target=dbhost01 -e DATABASE_NAME=ORCL01 -e TICKET_NUMBER=CHG0030001 \
  -e oracle_common_patch_checksum=sha256:<64 hex digits from a trusted source>

# 4. Full patch (same inputs).
ansible-playbook -i inventory/dev/hosts.yml --vault-id dev@prompt oracle_database_patch.yml \
  -e target=dbhost01 -e DATABASE_NAME=ORCL01 -e TICKET_NUMBER=CHG0030001 \
  -e oracle_common_patch_checksum=sha256:<64 hex digits from a trusted source>
```

Several databases of one shared home: add `-e oracle_patch_databases=ORCL01,ORCL02` (see
[Shared ORACLE_HOME](#shared-oracle_home)). Skip the change check (emergency, knowingly): `-e override_chg=true`.

## Job inputs

AAP survey questions or `-e` extra vars. The names are unchanged from the original playbooks.

| Input | Required | Description |
|---|---|---|
| `target` | yes | Comma or space separated host names or IP addresses. Used as the play hosts; hosts not in the inventory are added at run time. Each must be a host name or address (no placeholder). |
| `DATABASE_NAME` | yes | ORACLE_SID of the database to patch; key into `sid_server_dict`. Must fully match `[A-Za-z][A-Za-z0-9_]{0,29}`. |
| `TICKET_NUMBER` | for the change check | ServiceNow change number, checked against `oracle_common_ticket_number_regex` (default `\A[A-Za-z]{2,10}[0-9]{1,20}\Z`) whenever supplied. Shown on every card. Required by the change check; `oracle_common_ticket_required: true` makes it required always. |
| `override_chg` | no (default `false`) | `true` skips the ServiceNow change check. A real boolean now; the legacy strings `"true"` / `"false"` (and yes/no, on/off, 1/0) are still accepted. |
| `oracle_patch_databases` | no | Every SID of the shared home patched in this run (list, or comma/space separated string), including `DATABASE_NAME`. Default: `[DATABASE_NAME]`. New name: `oracle_common_patch_databases`. |
| `oracle_common_patch_checksum` | yes (here or in the inventory) | Checksum of this cycle's patch bundle. Alias `oracle_patch_checksum`. |
| `ansible_inventory_groups` | no | Groups the run-time added targets join. |
| `sid_server_dict` | yes (inventory) | Dictionary of databases keyed by ORACLE_SID: `dbowner`, `pdb`, `dbvip`, `dbListener`, `pdbListener` (see `inventory/example/group_vars/all/main.yml`). |

`sid_server_dict` keys: `dbowner` (POSIX user owning `ora_pmon_<SID>`; every database patched together must have the
same one), `pdb` (`""` for a non-CDB: the PDB listener steps are skipped), `dbvip` (pinged before startup and
shutdown; `""` skips the ping), `dbListener`, `pdbListener` (key kept even when empty). Listener and PDB names must be
Oracle names; `dbvip` a host name or IP address. The start/stop steps look the SID up in lower case first (as
before), then as given, then without case; differing upper- and lower-case entries for one SID are refused.

## Variable reference

Every setting below is a role default and can be set in the inventory (`group_vars`, `host_vars`) or as an extra
var. Most have a short `oracle_patch_*` alias or keep the original variable name as an alias; an alias, when set,
wins over the `oracle_common_*` default. The authoritative reference is each role's `meta/argument_specs.yml` and
the comments in its `defaults/`. Format checks that argument specs cannot express (anchored `\A..\Z` patterns, the
`..` path rule, mode normalisation, checksum format, `"<CHANGE_ME>"`) are in `roles/oracle_common/tasks/validate.yml`
and `validate_job.yml`.

### Patch bundle and repository (`roles/oracle_common/defaults/main/patch.yml`)

| Variable | Default | Aliases / notes |
|---|---|---|
| `oracle_common_patch_repo_url` | none (required) | Alias `artifactory_repo`. https base URL; the release folder (`artifact_dir`, e.g. `19.0.0`) is appended unless the URL already ends with it or it came from `artifactory_repo`. |
| `oracle_common_patch_repo_version_subdir` | `true`, or `false` when `artifactory_repo` is set | Append the release folder. |
| `oracle_common_patch_repo_version_check` | `true` | The repository folder must be the detected version's `artifact_dir` (replaces the original fixed-offset string comparison). |
| `oracle_common_patch_repo_allow_http` | `false` | Opt-in: accept a plain http URL (warning). |
| `oracle_common_patch_checksum` | none (required) | Alias `oracle_patch_checksum`. `<algorithm>:<hex digest>` with md5, sha1, sha224, sha256, sha384 or sha512 and exactly that digest length (not all zeros), or `<algorithm>:<https URL of a checksum file>`. |
| `oracle_common_patch_cycle` | `jan` | Alias `oracle_patch_cycle`. File name `<AIX\|LINUX>_<cycle><year>.tar.gz`. |
| `oracle_common_patch_year` | target's year, two digits | Alias `oracle_patch_year`. Two or four digits. |
| `oracle_common_patch_file_name` | derived | Aliases `oracle_patch_file_name`, `patch_file_name`. Explicit file name. |
| `oracle_common_patch_validate_certs` | `true` | Verify the repository's TLS certificate. `false` is an opt-in (warning; the checksum is still verified). |
| `oracle_common_patch_ca_path` | `""` | CA bundle (PEM, on the target), e.g. an internal CA. |
| `oracle_common_patch_use_proxy` | `false` | Use a proxy for the download (the original did not). |
| `oracle_common_patch_proxy` | `""` | Proxy URL when `oracle_common_patch_use_proxy` is true. |
| `oracle_common_patch_repo_username`, `oracle_common_patch_repo_password` | `vault_patch_repo_username` / `vault_patch_repo_password`, else `""` | HTTP basic authentication from the Vault; both or neither; never in the URL. |
| `oracle_common_patch_force_basic_auth` | `true` | Send the credentials with the first request (the original `force_basic_auth: yes`). |

### Staging layout (`patch.yml`, `staging.yml`, `environment_file.yml`)

| Variable | Default | Aliases / notes |
|---|---|---|
| `oracle_common_is_grid_layout` | `false` | Alias `is_grid_layout`; a real boolean, legacy `"true"`/`"false"` strings accepted (a boolean `false` now selects the Oracle layout; the original treated anything but the string `'false'` as Grid). |
| `oracle_common_patch_base_dir_oracle`, `oracle_common_patch_base_dir_grid` | `/u01/oracle`, `/u02/grid` | Patch base directory per layout. |
| `oracle_common_patch_owner_oracle`, `oracle_common_patch_owner_grid` | `oracle`, `grid` | Owner of the staged patch per layout. |
| `oracle_common_patch_base_dir` | selected by the layout | Alias `patch_folder_prefix`. |
| `oracle_common_patch_owner` | selected by the layout | Alias `b_user`. |
| `oracle_common_patch_staging_dir` | `<base dir>/software_dir/<staging component>/<cycle><year>_<SID>` | Alias `patch_folder_name`. Used exactly when given. |
| `oracle_common_staging_base` | `<oracle_common_patch_base_dir_oracle>/ansible_patch_work` | Base of the working directories (was the world-writable `/tmp`). Created by the database owner (0750) when missing. A world-writable parent without the sticky bit is refused; `/tmp` still works when set explicitly (warning). |
| `oracle_common_remote_script_directory` | `<staging base>/ora_ansible_scripts_<DATABASE_NAME>` | Alias `remote_script_directory`. |
| `oracle_common_remote_output_directory` | `<staging base>/ora_db_patch_<DATABASE_NAME>` | Alias `remote_output_directory`. Logs and script output (`ORA_WORK_DIR`). |
| `oracle_common_env_dir` | `/local` | Directory of the `<SID>.env` files. |
| `oracle_common_env_file` | `<env dir>/<DATABASE_NAME>.env` | Environment file sourced by the scripts (`ORA_ENV_FILE`). |

### Permissions and group membership (`modes.yml`, `group.yml`)

| Variable | Default | Aliases / notes |
|---|---|---|
| `oracle_common_script_permission` | `"0750"` | Alias `script_permission`. Copied scripts. |
| `oracle_common_dir_mode` | `"0750"` | Working, output and staging directories. |
| `oracle_common_file_mode` | `"0640"` | Downloaded bundle. The extracted tree gets `u=rwX,g=rX,o=`. |
| `oracle_common_work_group` | `""` (creating user's primary group) | Grid layout: the group the database owner and grid share, so the database owner can read the patch. |
| `oracle_common_manage_group_membership` | `true` | Add the database owner and the patch staging owner to the group (the original behaviour). |
| `oracle_common_group_name` | none (required while managed) | Alias `GROUP_NAME`. The original site group default is gone. |
| `oracle_common_group_membership_become_user` | `root` | User the membership change runs as through Ansible `become` (no raw sudo). |
| `oracle_common_group_add_command`, `oracle_common_group_members_command`, `oracle_common_group_members_regex` | per OS (`vars/Linux.yml`, `vars/AIX.yml`) | Linux: `/bin/gpasswd --add`, `/usr/bin/getent group`; AIX: `/usr/bin/chgrpmem -m +`, `/usr/sbin/lsgroup -a users`. Argument vectors. |

All modes are validated: an unquoted YAML mode (an integer such as `0777` = 511) is normalised to `'%04o'` first, and
group- or world-writable modes are rejected. 0777 is not allowed anywhere (no toggle).

### Platform and Oracle version (`platform.yml`, `oracle_versions.yml`)

| Variable | Default | Aliases / notes |
|---|---|---|
| `oracle_common_supported_systems` | `[Linux, AIX]` | Kernel names allowed by the guard. |
| `oracle_common_check_packages` | `true` | Check the prerequisite packages (AIX filesets) of the OS release. |
| `oracle_common_prereq_packages` | per OS release file | Packages that must be installed; empty skips the check with a message. |
| `oracle_common_artifact_platform` | `LINUX` / `AIX` | Prefix of the bundle file name. |
| `oracle_common_package_manager`, `oracle_common_package_query_command`, `oracle_common_package_query_regex` | per OS | `rpm` package_facts on the Red Hat family; `lslpp -Lc` on AIX. |
| `oracle_common_db_version` | `""` (detect) | Alias `oracle_patch_db_version`. Force a version file, e.g. `26ai`. |
| `oracle_common_oracle_version_overrides` | `{}` | Per-version overrides, keyed by version. |

### Scope, shared home, outcome, timeouts (`safety.yml`)

| Variable | Default | Aliases / notes |
|---|---|---|
| `oracle_common_patch_databases` | `[DATABASE_NAME]` | Alias `oracle_patch_databases`. |
| `oracle_common_allow_shared_home_partial` | `false` | Alias `oracle_patch_allow_shared_home_partial`. Opt-in, see [Shared ORACLE_HOME](#shared-oracle_home). |
| `oracle_common_oratab` | `/etc/oratab` | Alias `oracle_patch_oratab` (`ORA_ORATAB`). |
| `oracle_common_env_glob` | `<env dir>/*.env` | Environment files read for their ORACLE_HOME (`ORA_ENV_GLOB`). |
| `oracle_common_bash_path` | `/usr/bin/bash` | Shell that reads ORACLE_HOME from an environment file. |
| `oracle_common_fail_when_already_applied` | `false` | Alias `oracle_patch_fail_when_already_applied`. See [Patch already applied](#patch-already-applied). |
| `oracle_common_unique_work_dirs` | `true` | Alias `oracle_patch_unique_work_dirs`. See [Working directories](#working-directories-and-cleanup). |
| `oracle_common_run_id` | generated | Alias `oracle_patch_run_id`. `[A-Za-z0-9][A-Za-z0-9_-]{0,63}`; default `<AAP job id>_<UTC time>_<8 hex>`. |
| `oracle_common_opatch_backup_dir` | `""` (`$ORACLE_HOME/OPatch.bak.<timestamp>`) | Alias `oracle_patch_opatch_backup_dir`. Where the replaced OPatch is kept. |
| `oracle_common_jvm_components_file` | `db_jvm_components.txt` | Java components file written by the status check. |
| `oracle_common_patch_timeout` | `14400` | Alias `oracle_patch_apply_timeout`. Seconds a patch step may run (was 4000 while polling for 14400). |
| `oracle_common_patch_poll_delay` | `120` | Alias `oracle_patch_poll_delay`. |
| `oracle_common_patch_poll_retries` | timeout / delay (120) | Alias `oracle_patch_poll_retries`. retries x delay may not exceed the timeout. |

### Start and stop (`roles/standalone_control_role/defaults/main.yml`)

| Variable | Default | Aliases / notes |
|---|---|---|
| `standalone_control_role_shutdown_verify_retries`, `standalone_control_role_shutdown_verify_delay` | `12`, `10` | Aliases `oracle_patch_shutdown_verify_retries`, `oracle_patch_shutdown_verify_delay`. Checks for `ora_pmon_<SID>` after a shutdown. |
| `standalone_control_role_fail_on_rename_logs_error` | `false` | `true` restores the original: a log rotation exit code 4 fails the startup before the database starts. |
| `standalone_control_role_fail_on_alert_log_errors` | `false` | `true`: ORA- errors in the alert log fail the startup (default: WARNING, as before). |
| `standalone_control_role_fail_on_listener_log_errors` | `false` | `true`: listener log errors fail the startup (default: WARNING, as before). |
| `standalone_control_role_alert_log_check_log` | `log.<check_alert_log script>` (`log.check_alert_log.bash`) | Alert log check log prefix; `log.check_mount.bash` restores the original file name. |
| `standalone_control_role_time_to_pause` | `120` | Alias `timeToPause`. Accepted, unused (as in the original). |
| `standalone_control_role_remote_script_directory_base`, `standalone_control_role_remote_output_directory_base` | `/tmp/ora_ansible_scripts_<SID>`, `~/ansiblescripts/startup/log` | Aliases `remote_script_directory_base`, `remote_output_directory_base`. Accepted, unused (as in the original). |
| `standalone_control_role_role_version` | `v1.0.0` | Metadata, unused. |
| `standalone_control_role_sid`, `standalone_control_role_environment` | `""`, `{}` | Set by `oracle_control_sid.yml` (SID as given; `ORA_ENV_FILE` in a patch run). |

Control script file names (in `roles/standalone_control_role/files/`); each original variable name is still accepted
as an alias and wins when set:

| Variable | Default | Alias (original name) |
|---|---|---|
| `standalone_control_role_check_mount_script` | `check_mount.bash` | `check_mount_script` (shipped, not run, as before) |
| `standalone_control_role_check_timestamp_script` | `check_timestamp.bash` | `check_timestamp_script` (shipped, not run, as before) |
| `standalone_control_role_check_alert_log_script` | `check_alert_log.bash` | `check_alertLog_script` |
| `standalone_control_role_check_listener_logs_script` | `check_listener_logs.bash` | `check_listenerLogs_script` |
| `standalone_control_role_rename_logs_script` | `rename_logs.bash` | `rename_logs_script` |
| `standalone_control_role_start_database_script` | `database_ctl.bash` | `start_database_script` |
| `standalone_control_role_start_listener_script` | `listener_ctl.bash` | `start_listener_script` |
| `standalone_control_role_start_pdb_script` | `pdb_ctl.bash` | `start_pdb_script` (shipped, not run, as before) |
| `standalone_control_role_start_pdb_listener_script` | `listener_ctl.bash` | `start_pdbListener_script` (accepted, not run: the PDB listener is started with the start listener script; the original `pdb_listener_ctl.bash` never existed) |
| `standalone_control_role_stop_pdb_script` | `pdb_ctl.bash` | `stop_pdb_script` (shipped, not run, as before) |
| `standalone_control_role_stop_pdb_listener_script` | `listener_ctl.bash` | `stop_pdbListener_script` |
| `standalone_control_role_stop_database_script` | `database_ctl.bash` | `stop_database_script` |
| `standalone_control_role_stop_listener_script` | `listener_ctl.bash` | `stop_listener_script` |

`oracle_control_sid.yml` keeps its interface: `control: startup | shutdown` becomes `control_command`; `ORACLE_SID` is
the lower-cased SID (as before); `server_name` is now the current host (`inventory_hostname`; it used to be the whole
`target` string, which broke runs with several targets). An explicit `server_name` extra var still wins.

### Teams notification (`notify.yml`)

| Variable | Default | Aliases / notes |
|---|---|---|
| `oracle_common_notify_webhook_url` | `teams_webhook_url`, else `vault_teams_webhook_url`, else `""` | Secret. Empty or not https: the card is skipped with a message. Still holding `"<CHANGE_ME>"`: the target-side input validation (`validate.yml`) refuses the whole run; delete the vault entry to run without notifications. |
| `oracle_common_notify_enabled` | `true` | `false` turns the cards off. |
| `oracle_common_notify_validate_certs` | `true` | |
| `oracle_common_notify_ca_path` | `""` | CA bundle on the sending host. |
| `oracle_common_notify_proxy` | `""` | Alias `notify_proxy` (replaces the hard-coded proxy). |
| `oracle_common_notify_timeout` | `30` | Seconds. |
| `oracle_common_notify_delegate_to` | `localhost` | Host that posts the card; `""`: the host running the play. |
| `oracle_common_notify_aap_base_url` | `""` | Alias `aap_base_url`. Job link base (empty: the URL fact is `n/a`). |
| `oracle_common_notify_job_url_path` | `/#/jobs/playbook/` | AAP 2.5 and later: `/execution/jobs/playbook/`. |
| `oracle_common_notify_states`, `oracle_common_notify_default_state` | every original state | See [Teams notifications](#teams-notifications-teams-workflows-webhook). |
| `awx_user_name`, `awx_schedule_name`, `awx_job_id`, `awx_job_template_name` | provided by AAP | Then the original `tower_user_name`, `tower_schedule_name`, `tower_job_id`, `tower_job_template_name`, then `scheduler`, `manual job`, `n/a`, `manual run` (CLI). |

### ServiceNow (`servicenow.yml`, `inputs.yml`)

| Variable | Default | Aliases / notes |
|---|---|---|
| `oracle_common_override_chg` | `override_chg`, else `false` | Skip the change check. |
| `oracle_common_snow_instance` | `snow_instance`, else `vault_snow_instance` | https URL or bare instance name. Secret. |
| `oracle_common_snow_username` | `snow_user`, else `vault_snow_user` | Secret. |
| `oracle_common_snow_password` | `snow_password`, else `vault_snow_password` | Secret. |
| `oracle_common_snow_instance_domain` | `service-now.com` | Appended to a bare instance name. |
| `oracle_common_snow_validate_certs` | `true` | |
| `oracle_common_snow_timeout` | `30` | Seconds. |
| `oracle_common_snow_proxy` | `""` | Alias `snow_proxy` (replaces the hard-coded proxy). |
| `oracle_common_snow_allowed_state_min`, `oracle_common_snow_allowed_state_max` | `-2`, `-1` | Allowed numeric change states (Scheduled .. Implement, the original check). |
| `oracle_common_snow_change_states` | `new -5, assess -4, authorize -3, scheduled -2, implement -1, review 0, closed 3, canceled 4` | State names returned by `servicenow.itsm` -> numeric states. |
| `oracle_common_ticket_number_regex` | `\A[A-Za-z]{2,10}[0-9]{1,20}\Z` | Must be anchored with `\A` and `\Z`. |
| `oracle_common_ticket_required` | `false` | Require `TICKET_NUMBER` in every run. |

### Failure report (`failure.yml`)

| Variable | Default | Notes |
|---|---|---|
| `oracle_common_failure_msg_max_length` | `2000` | Longest error message kept from the failed task. |
| `oracle_common_failure_output_lines` | `10` | Last output lines added to the report; `0` leaves them out. |

### Role entry points (tasks_from) and their include variables

These are set by the playbooks (or by tests) when they include a task file, not by the inventory:

| Entry point | Include variables |
|---|---|
| `oracle_common` `main` | none (the variables above) |
| `oracle_common` `validate_job`, `preflight_scope` | the job inputs |
| `oracle_common` `notify` (via `notification.yml`) | `call`, `summary_state` |
| `oracle_common` `change_ticket` (via `oracle_chg_ticket.yml`) | none |
| `oracle_common` `failure_record` | `oracle_common_failure_stage` |
| `oracle_common` `failure_report` | `oracle_common_failure_stage`, `oracle_common_failure_call` (default `fail`), `oracle_common_failure_summary_state` (default `patching`), `oracle_common_failure_cleanup_done` (default `false`) |
| `oracle_common` `progress` | `oracle_common_progress_update`, e.g. `{databases: {ORCL01: stopped}}` |
| `oracle_common` `oracle_version_select` | `oracle_common_detected_version` |
| `oracle_common` `guard_os_release` | `oracle_common_os_release_text` |
| `oracle_common` `shared_home` | none |
| `oracle_database_patch_role` `run_prereq`, `main`, `clean_files_from_server` | none |
| `oracle_database_patch_role` `copy_files_to_server` | `artf_file_name`, `temp_dir` (set by `run_prereq`) |
| `standalone_control_role` `main` (via `oracle_control_sid.yml`) | `control` -> `control_command` |

### Original names that are internal facts

`ORACLE_SID`, `server_name`, `remote_script_directory`, `remote_output_directory`, `db_ver_long`, `db_ver`,
`artf_ver`, `patch_file_prefix`, `patch_file_name`, `patch_folder_prefix`, `b_user`, `patch_folder_name`,
`missing_packages`, `check_if` (`one` / `two` / `three`) and `notification_call` are still set by the roles and
playbooks for compatibility. The inputs among them (`remote_*_directory`, `patch_file_name`, `patch_folder_prefix`,
`b_user`, `patch_folder_name`) are accepted as aliases above. `call` and `summary_state` remain the interface of
`notification.yml`; `control` that of `oracle_control_sid.yml`.

### Script-only settings

`database_patch.bash` also reads `ORA_ENV_FILE_ALLOW_ANY_OWNER`, `ORA_DB_PATCH_ID`, `ORA_JVM_PATCH_ID`, `ORA_OPATCH_UPGRADE`, `ORA_STATUS_STARTUP`,
`ORA_APPLY_JVM`, `ORA_FAIL_ON_NEW_INVALID_OBJECTS`, `ORA_UTLRP_MAX_RETRIES`, `ORA_PS_EXCLUDE_PATTERN` and others
(listed in its header); their defaults reproduce the original behaviour. The playbooks do not set them yet: the
playbooks pass `ORA_ENV_FILE`, `ORA_WORK_DIR`, `ORA_ORATAB`, `ORA_ENV_GLOB`, `ORA_OPATCH_BACKUP_DIR` (when set) and the
per-version `ORA_DB_RU_PATTERN`, `ORA_JVM_RU_PATTERN`, `ORA_JVM_MIN_MATCHES` and `ORA_DATAPATCH_STARTUP_MODE`.

## Shared ORACLE_HOME

OPatch patches the Oracle home, not a database: every database that runs from the home goes down with it and needs
datapatch afterwards. Before anything is stopped or changed, the full patch run lists every database that uses the
ORACLE_HOME of `DATABASE_NAME` (`home_inventory.bash`, read-only: `/etc/oratab` entries, running `ora_pmon_<SID>`
processes of that home, and environment files `<env dir>/*.env` naming it; for the path as written in the
environment file and, when different, for the physical path) and **refuses unless all of them are in scope**:

```sh
ansible-playbook ... oracle_database_patch.yml -e DATABASE_NAME=ORCL01 -e oracle_patch_databases=ORCL01,ORCL02
```

Refused, naming the SIDs, before anything is stopped:

- a running database on the home that is not in scope (always; stopping a database nobody asked to stop is never
  done);
- a stopped database on the home that is not in scope, unless `oracle_common_allow_shared_home_partial: true`
  (alias `oracle_patch_allow_shared_home_partial`; for stale oratab entries or decommissioned databases, which then
  get no datapatch);
- a database in scope whose ORACLE_HOME cannot be read, or that uses another home;
- a home that cannot be listed reliably (the listing failed, was malformed, or did not include `DATABASE_NAME`).

Every database in scope needs a `sid_server_dict` entry with the same `dbowner`. With several databases the run
stops all of them (and their listeners) and verifies each is down, applies the patch to the home once (as a database
whose status check recorded Java, so the OJVM patch reaches the home), runs datapatch in each database and starts
them all. A patch applied in some in-scope databases but not others is refused. SIDs are compared without case.
The prerequisite playbook only reports databases out of scope as warnings (scope errors still fail).

## Patch already applied

When the status check finds the patch applied in **every** database in scope (`database_patch.bash status` exit
code 2), the run cleans up, sends the blue **unneeded** card ("been skipped; unneeded") and ends successfully for
that host, without stopping anything. A re-run after a successful run therefore changes nothing.

`oracle_common_fail_when_already_applied: true` (alias `oracle_patch_fail_when_already_applied`) restores the
original outcome: the same unneeded card, then the run fails. Only exit code 2 means unneeded; a failed status check
is a failure (red card); the original also sent "unneeded" for those.

## Working directories and cleanup

With `oracle_common_unique_work_dirs: true` (default), every run uses its own script, output and staging directories
(the configured names plus `_<run id>`), created fresh by the owning user with `oracle_common_dir_mode`; a path that
already exists or a planted symbolic link is refused. Further databases in scope work in `<output dir>/<SID>`. The
cleanup removes only the script and staging directories this run recorded; the logs in the output directory are kept
(as before). `false` restores the original fixed names, removed and re-created at the start of a run. Directories
given explicitly (`remote_script_directory`, `remote_output_directory`, `patch_folder_name` /
`oracle_common_patch_staging_dir`) are used exactly as given and handled like the fixed names, so the next run can
use them again. Nothing is cleaned up after a failed patch step (the staging is kept for diagnosis), as before.

## Secrets with Ansible Vault

Secrets live only in Ansible Vault, one vault id per environment (`dev`, `test`, `prod`), never in the repository,
in plain inventory files or in job extra vars. Never paste a secret into a chat or ticket either.

| Vault variable | Feeds |
|---|---|
| `vault_teams_webhook_url` | `oracle_common_notify_webhook_url` |
| `vault_snow_instance`, `vault_snow_user`, `vault_snow_password` | `oracle_common_snow_instance`, `_username`, `_password` |
| `vault_patch_repo_username`, `vault_patch_repo_password` | `oracle_common_patch_repo_username`, `_password` |

```sh
cp inventory/<env>/group_vars/all/vault.yml.example inventory/<env>/group_vars/all/vault.yml
$EDITOR inventory/<env>/group_vars/all/vault.yml
ansible-vault encrypt --vault-id <env>@prompt inventory/<env>/group_vars/all/vault.yml
head -n 1 inventory/<env>/group_vars/all/vault.yml      # $ANSIBLE_VAULT;1.2;AES256;<env>
ansible-playbook -i inventory/<env>/hosts.yml --vault-id <env>@prompt oracle_database_patch.yml -e ...
```

Edit with `ansible-vault edit --vault-id <env>@prompt <file>`, rotate with
`ansible-vault rekey --vault-id <env>@prompt --new-vault-id <env>@prompt <file>`. In AAP, create one Vault credential
per environment (Vault Identifier = the environment name) and attach it to that environment's job templates.
`.gitignore` excludes vault password files (`.vault_pass*`, `vault_pass*`). Every task that handles a secret runs
with `no_log`. Details: `inventory/README.md`.

## Teams notifications (Teams Workflows webhook)

The retired Office 365 connector card is replaced by an Adaptive Card posted to a Teams Workflows webhook with
`ansible.builtin.uri` (TLS verified, `no_log`). **Best effort**: a card that is skipped (notifications off, URL
empty or not https; reported with a message) or cannot be sent (WARNING) never fails the run. The exception is a URL
still holding the `"<CHANGE_ME>"` placeholder: input validation on the targets refuses the run before patching. Cards are posted from `localhost` by default (`oracle_common_notify_delegate_to`).

Set up: in the Teams channel, Workflows -> the template "Post to a channel when a webhook request is received"
(trigger "When a Teams webhook request is received", action "Post card in a chat or channel"), copy the URL it shows
and store it only in the environment's vault as `vault_teams_webhook_url`. The URL is a bearer secret.

| summary_state | call | Text | Colour (was) |
|---|---|---|---|
| `patching` | `start` | Database patching has started | Good (13E81D) |
| `patching` | `success` | completed | Accent (11A8E8) |
| `patching` | `unneeded` | been skipped; unneeded | Accent (11A8E8) |
| `patching` | `fail` | failed | Attention (f21818) |
| `prereq` | `start_prereq` | Database prerequisite check has started | Good |
| `prereq` | `success_prereq` | completed | Accent |
| `prereq` | `failure` (any other) | failed | Attention |

Any unknown `call` sends a red failure card (as before). Card title `Job #<job id> '<job template>'`; facts Database,
Host, Change Ticket, URL, Running User, Scheduled Job Name; a "View job" button when `oracle_common_notify_aap_base_url`
is set and the job id is known (AAP). Both playbooks currently send the `patching` cards (the prerequisite playbook did so originally too); the
`prereq` states remain available to `notification.yml` callers.

## ServiceNow change check

`oracle_chg_ticket.yml` (full patch playbook only) runs `servicenow.itsm.change_request_info` for `TICKET_NUMBER`
(the retired `servicenow.servicenow.snow_record_find` is gone). The record must exist (exactly one) and its state
must be within `oracle_common_snow_allowed_state_min` .. `_max` (default -2 Scheduled .. -1 Implement, the original
check); state names returned by the collection are mapped with `oracle_common_snow_change_states`. Credentials come
from the vault (or the original `snow_instance`, `snow_user`, `snow_password`); every task touching them is
`no_log`, and only the ticket number and the record state are printed. `override_chg: true` skips the check with a
message. A failed check sends the red card and stops the run before any host is touched.

## Security defaults

| Area | Default | Opt-in / note |
|---|---|---|
| SSH host keys | checked (`host_key_checking = True`) | Bootstrap only: `ANSIBLE_HOST_KEY_CHECKING=False` in the environment, temporarily. |
| World-readable temp files | not allowed | Become to the database owner needs the `acl` package (setfacl), `ansible_common_remote_group`, or a root connection (`ansible.cfg`). Never set `ansible_become_user`. |
| Privilege | `become` (method from `ansible_become_method`); no raw `sudo` | Group membership runs as `oracle_common_group_membership_become_user` (root); the sudo rule must allow Ansible become, or set `oracle_common_manage_group_membership: false`. |
| Commands | `ansible.builtin.command` with `argv`, values in the environment; no `shell` module | |
| Download | TLS verified, checksum required, credentials from the vault, `no_log` | `oracle_common_patch_validate_certs: false`, `oracle_common_patch_repo_allow_http: true` (warnings). |
| Modes | scripts 0750, directories 0750, bundle 0640, extracted tree `u=rwX,g=rX,o=` | Group/world-writable modes rejected; 0777 removed (no toggle). |
| Working directories | private base under the Oracle base, per run | `/tmp` only when set explicitly (warning). |
| Inputs | anchored `\A..\Z` patterns, `..` path components rejected, `"<CHANGE_ME>"` rejected | |
| Environment files | sourced only when owned by the user running the script (the database owner) or root and not world-writable; an empty, `.` or relative PATH entry is dropped after sourcing | `ORA_ENV_FILE_ALLOW_ANY_OWNER=true` (script environment only, not set by the playbooks). |

## AAP usage and migrating existing job templates

Job template: project = this repository, playbook `oracle_database_patch.yml` or `oracle_database_patch_prereq.yml`,
inventory = the environment's inventory (an AAP inventory source pointing at `inventory/<env>/hosts.yml`), a machine
credential for the connection user, and the environment's **Vault credential**. The execution environment needs
ansible-core 2.22, `ansible.posix` and `servicenow.itsm` (`collections/requirements.yml`), and the targets' SSH host
keys (known_hosts in the image or a mounted file).

What to change in an existing job template:

| Item | Before | Now |
|---|---|---|
| Survey `target`, `DATABASE_NAME`, `TICKET_NUMBER` | as is | unchanged (now validated). |
| `override_chg` | the string `"false"` / `"true"`; undefined failed the run, and a boolean `false` silently skipped the check | boolean or the legacy strings; default `false` (check runs). |
| Patch checksum | none | **new, required**: `oracle_common_patch_checksum` (alias `oracle_patch_checksum`), per cycle. |
| Repository URL | `artifactory_repo` extra var (required in practice) | `artifactory_repo` still accepted, or `oracle_common_patch_repo_url` in the inventory; https required. |
| `GROUP_NAME` | defaulted to a site group | **required** while group membership is managed, or set `oracle_common_manage_group_membership: false`. |
| Patch cycle | always `jan` of the target's year | `oracle_patch_cycle` / `oracle_patch_year` / `oracle_patch_file_name` (default unchanged). |
| Shared home | only `DATABASE_NAME` was stopped | add `oracle_patch_databases` when the home is shared, or the run is refused. |
| Teams webhook | Office 365 connector URL in code | `vault_teams_webhook_url` in the vault (Vault credential). |
| ServiceNow credentials | `snow_user` / `snow_password` / `snow_instance` extra vars | the vault (`vault_snow_*`); the original names are still accepted. |
| Job link on the card | hard-coded Tower URL | `aap_base_url` / `oracle_common_notify_aap_base_url`; AAP 2.5+: `oracle_common_notify_job_url_path: /execution/jobs/playbook/`. |
| Job variables | `tower_*` only (failed on the CLI) | `awx_*` first, then `tower_*`, then CLI defaults. |

## Failure report

Every rescue of both playbooks ends with the same report: the red card (best effort), then a failure such as

```
Fail: <stage> failed on <host> in task '<task>': <error> (exit code <rc>). Last output: <last lines>.
State left behind: databases: ...; Oracle home: ...; files: ....
```

for example `Fail: Validate the job inputs failed on localhost in task 'Validate the job inputs': Invalid or missing
job inputs: ... State left behind: databases: ORCL01 not stopped by this run; Oracle home: not changed by this run;
files: none created on the host by this run.`

It names the stage, the failed task, its error, and the state left behind: databases this run stopped or failed to
start, whether the Oracle home was patched (`UNKNOWN` after a failed patch step), where datapatch ran, and which files
were kept or removed. A failed patch step leaves the databases down and the staging in place for the DBA.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `target is required` | Pass `-e target=<host>` (AAP: the survey question). |
| `... still contains the placeholder <CHANGE_ME>` | A skeleton value was not replaced (`inventory/<env>/`); the message names the variables. |
| `oracle_common_patch_checksum ... required` | Pass this cycle's checksum (`-e oracle_common_patch_checksum=sha256:...`). |
| `Failed: <distribution> <version> is not supported` | EL7 and older and Amazon Linux 2 are refused; upgrade the host. |
| `Refusing to patch the Oracle home ...` | Other databases use the home: add them to `oracle_patch_databases` (the message names them). |
| `... has no entry for DATABASE_NAME` | Add the SID to `sid_server_dict` in `group_vars/all/main.yml`. |
| Database owner check fails | `DATABASE_NAME` must be running and owned by `sid_server_dict[<SID>].dbowner` at the start. |
| `Database version ... is not supported` / `... matches several supported versions` / `oracle_common_db_version ... does not accept` | Add or override a file in `vars/oracle_versions/` (`oracle_common_oracle_version_overrides`), or set `oracle_common_db_version` (26ai). |
| Repository folder mismatch | The URL names another release; fix `oracle_common_patch_repo_url` or set `oracle_common_patch_repo_version_check: false` for a repository not organised by release. |
| Download fails | The message gives the HTTP status (URL and credentials removed). Internal CA: `oracle_common_patch_ca_path`. |
| `Permission denied` / `Failed to set permissions` when becoming the database owner | Install `acl` on Linux, set `ansible_common_remote_group`, or connect as root (`ansible.cfg`). |
| `environment file is owned by another user` / `is world-writable` | The `<SID>.env` file must belong to the database owner or root and not be world-writable; fix its ownership and mode. |
| Host key verification failed | Add the target's key to known_hosts (verify the fingerprint out of band). |
| ServiceNow `required, from the Ansible Vault` | Create the environment's `vault.yml` and pass `--vault-id <env>@prompt` (AAP: attach the Vault credential). |
| No Teams card | The webhook is empty or not https (the run shows why), or the post failed (WARNING). A webhook still holding `"<CHANGE_ME>"` does not just skip the card: input validation on the targets refuses the run (`oracle_common_notify_webhook_url: still the placeholder`); replace it or delete `vault_teams_webhook_url`. |
| Shutdown verification fails | The database did not stop within retries x delay (`standalone_control_role_shutdown_verify_*`). |
| Re-run after a partial patch | If the home was patched but datapatch did not run everywhere, the failure report names the databases; run datapatch for them (re-running relies on OPatch's handling of an installed patch). |

## Testing

Local checks (CI, `.github/workflows/ci.yml` job `lint`, runs yamllint, shellcheck of `roles/*/files/*.bash`, both
syntax checks and ansible-lint):

```sh
yamllint .
shellcheck roles/*/files/*.bash tests/shell/*.bash
ansible-playbook -i inventory/example/hosts.yml --syntax-check oracle_database_patch.yml -e target=dbhost01.example.com
ansible-playbook -i inventory/example/hosts.yml --syntax-check oracle_database_patch_prereq.yml -e target=dbhost01.example.com
ansible-lint                               # production profile, 0 failures, 0 warnings, no skip list
for t in tests/*.yml; do ansible-playbook -i localhost, -c local "$t" || break; done   # controller only, change nothing
tests/shell/run.bash                       # script tests with stubbed sqlplus, opatch, datapatch, lsnrctl
```

The test playbooks cover input validation and placeholders, the legacy aliases, platforms and Oracle versions, the
shared-home decision, the already-applied outcome, scope and working directories, the download (checksum, TLS,
modes), group membership, the start/stop commands, notifications, the change check, the failure report and static
security rules. Molecule scenarios (containers with stubbed Oracle tools) need a container runtime and are run in CI
only; without one they are not executed locally. A real RHEL or AIX host with Oracle Database is needed for the final
validation (owner).

## Extending

- **A Linux distribution or release**: add one file `roles/oracle_common/vars/<os_family>-<major>.yml` or
  `<distribution>-<major>.yml` (files load generic first, most specific last: `<system>`, `<os_family>`,
  `<distribution>`, `<os_family>-<major>`, `<distribution>-<major>`), usually just `__oracle_common_prereq_packages`.
- **An Oracle version**: add one file `roles/oracle_common/vars/oracle_versions/<version>.yml` with the keys listed
  under [Supported Oracle versions](#supported-oracle-versions) (checked when the registry is loaded).

## License

The automation code is licensed under the GNU General Public License v3.0 or later (SPDX: `GPL-3.0-or-later`), see
`LICENSE`. `NOTICE` lists what the grant does not cover: Oracle Database, OPatch, Oracle patches and their formats,
RHEL and AIX packages, downloaded artifacts and trademarks remain under their owners' terms.
