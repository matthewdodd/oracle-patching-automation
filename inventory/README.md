# Inventories

One directory per environment. `dev/`, `test/` and `prod/` are skeletons with default names: rename them or add
more to match your environments. `example/` is a filled-in reference with example values only; CI and the tests
use it.

```
inventory/<env>/
  hosts.yml                          hosts, in group oracle_db_servers (one "<CHANGE_ME>" placeholder host in the skeletons)
  group_vars/all/main.yml            sid_server_dict: the databases of the environment (non-secret)
  group_vars/all/oracle_common.yml   environment configuration (non-secret) and the wired vault_* mappings
  group_vars/all/vault.yml.example   placeholder secrets and the vault steps for this environment (not loaded)
  group_vars/all/vault.yml           secrets, encrypted with --vault-id <env> (you create it; never committed unencrypted)
  host_vars/<host>.yml               per-host overrides (optional)
```

The variables live in `group_vars/all/` (not in a host group) on purpose: the change check and the notifications
run on `localhost`, which reads `group_vars/all` but no other group, and hosts passed only in `-e target=...` are
members of `all` too, so they get the environment configuration without `-e ansible_inventory_groups=...`.

Always pass the inventory explicitly (`ansible.cfg` names none):

```sh
ansible-playbook -i inventory/<env>/hosts.yml --vault-id <env>@prompt oracle_database_patch.yml \
  -e target=<host> -e DATABASE_NAME=<SID> -e TICKET_NUMBER=<change number>
```

## Filling in a skeleton

Every `"<CHANGE_ME>"` is a placeholder that the validation rejects, so an unedited skeleton stops before it
changes any host: `sid_server_dict` is checked on `localhost` first (roles/oracle_common `tasks/validate_job.yml`),
and every `oracle_common_*` value on each target before anything else runs (`tasks/validate.yml`). The placeholder
host is not a valid host name either: it is rejected as a `target`, and it is never contacted (the first play only
runs controller-side tasks).

1. `hosts.yml`: replace the `"<CHANGE_ME>":` host with the environment's database servers.
2. `group_vars/all/main.yml`: replace the `"<CHANGE_ME>"` entry of `sid_server_dict` with one entry per database
   (`dbowner`, `pdb`, `dbvip`, `dbListener`, `pdbListener`; see the comments in the file and
   `inventory/example/group_vars/all/main.yml`).
3. `group_vars/all/oracle_common.yml`: replace the three required placeholders:
   - `oracle_common_patch_repo_url`: the https base URL of the patch repository;
   - `oracle_common_patch_checksum`: the checksum of the patch bundle (usually passed per job instead, because it
     changes with every patch cycle; the value here is the fallback);
   - `oracle_common_group_name`, or set `oracle_common_manage_group_membership: false` and delete that line.

   Each is written as `"{{ <original name> | default('<CHANGE_ME>') }}"` (`artifactory_repo`,
   `oracle_patch_checksum`, `GROUP_NAME`), so job templates that still pass the original input names keep working.
   Replace only the `'<CHANGE_ME>'` inside the quotes to keep that. Optional settings are listed, commented out,
   with their defaults.
4. Secrets (Teams webhook URL, ServiceNow instance and credentials, patch repository credentials): create
   `vault.yml` as below. The `vault_*` mappings at the end of `oracle_common.yml` are already wired; without
   `vault.yml` there is no notification, no repository credentials, and the ServiceNow change check fails unless the
   job sets `override_chg`.

## Renaming or adding an environment

- Rename: `git mv inventory/dev inventory/<name>`, replace `dev` in the comments of its files, and use `<name>` as
  the vault id (`--vault-id <name>@prompt`, and the Vault Identifier of the AAP Vault credential). A `vault.yml`
  that already exists must be re-keyed to the new id:
  `ansible-vault rekey --vault-id dev@prompt --new-vault-id <name>@prompt inventory/<name>/group_vars/all/vault.yml`.
- Add: `cp -R inventory/test inventory/<name>`, replace `test` in the copied comments, and give it its own vault id
  and vault password.

## Secrets (Ansible Vault)

One vault id and one vault password per environment, so a dev password never opens test or prod secrets:

```sh
cp inventory/<env>/group_vars/all/vault.yml.example inventory/<env>/group_vars/all/vault.yml
$EDITOR inventory/<env>/group_vars/all/vault.yml          # real values; delete the entries you do not use
ansible-vault encrypt --vault-id <env>@prompt inventory/<env>/group_vars/all/vault.yml
head -n 1 inventory/<env>/group_vars/all/vault.yml        # $ANSIBLE_VAULT;1.2;AES256;<env>
```

| Vault variable | Feeds | Needed |
|---|---|---|
| `vault_teams_webhook_url` | `oracle_common_notify_webhook_url` | for Teams notifications (skipped without it) |
| `vault_snow_instance`, `vault_snow_user`, `vault_snow_password` | `oracle_common_snow_instance`, `_username`, `_password` | for the ServiceNow change check (unless `override_chg`) |
| `vault_patch_repo_username`, `vault_patch_repo_password` | `oracle_common_patch_repo_username`, `_password` | only for a repository that needs HTTP basic authentication (both or neither) |

Edit later with `ansible-vault edit --vault-id <env>@prompt ...`; rotate the password with
`ansible-vault rekey --vault-id <env>@prompt --new-vault-id <env>@prompt ...`. In AAP, attach a Vault credential
whose Vault Identifier is `<env>` to the environment's job templates (no `--vault-id` option is needed there).

Never commit an unencrypted `vault.yml` or a vault password file (`.gitignore` excludes `.vault_pass*` and
`vault_pass*`), and never paste a secret into a chat, a ticket or a job's extra vars. Check before every commit that
`head -n 1` of each `vault.yml` starts with `$ANSIBLE_VAULT;`. If an unencrypted secret was ever committed, it is in
the git history: rotate it, then encrypt the file.
