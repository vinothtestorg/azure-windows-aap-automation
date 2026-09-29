# Runbook: rotate the `sp-aap-poc` service principal secret (I5)

Scope: rotate the Azure SP client secret that backs AAP's `azure-sp-poc`
(Microsoft Azure Resource Manager) and `azure-kv-poc` (Microsoft Azure Key
Vault) credentials, and push the new value into AAP. Nothing here prints a
secret value - only lengths, status codes, or `changed`/`ok` counts.

## Why this is two steps, not one

`infra/scripts/create-aap-sp.sh --rotate` only writes the new secret to Key
Vault (`aap-sp-client-secret`). `aap/configure.yml` reads Key Vault and
writes AAP's `azure-sp-poc`/`azure-kv-poc` credentials on every run, but by
default it never overwrites a secret field AAP already has
(`update_secrets: false` on both credentials, and on the `svc-github-cd`
user's password) - this is deliberate: `update_secrets: true` unconditionally
resets the field, which would defeat this playbook's `changed=0` idempotent
re-run guarantee for the common case (nothing rotated, just re-applying the
same config). Rotation therefore needs an explicit opt-in:
`-e aap_update_secrets=true`.

## Procedure

1. Rotate the secret in Key Vault (does not touch AAP):
   ```bash
   bash infra/scripts/create-aap-sp.sh --rotate
   ```
   This resets the `sp-aap-poc` app registration's credential (45-day
   expiry from today) and writes the new value to Key Vault secret
   `aap-sp-client-secret`. It never prints the secret - only
   `sp-aap-poc appId=<appId>`.

2. Push the new secret into AAP's `azure-sp-poc` and `azure-kv-poc`
   credentials (and, if the Key Vault CD user password was also rotated
   separately, the `svc-github-cd` user):
   ```bash
   set -a; . ./.env.aap; set +a
   ansible-playbook aap/configure.yml -e aap_update_secrets=true
   ```
   Expect `changed` on exactly the `Ensure Microsoft Azure Resource Manager
   credential azure-sp-poc exists` and `Ensure Microsoft Azure Key Vault
   credential azure-kv-poc exists` tasks (and on the user task only if that
   password also changed) - every other task should still be `ok`.

3. Re-run `configure.yml` **without** `-e aap_update_secrets=true` and
   confirm `changed=0` again - this is the idempotency check that proves
   the rotation "took" (AAP's credential now matches Key Vault, so there is
   nothing left to push):
   ```bash
   ansible-playbook aap/configure.yml
   ```

4. Verify AAP can still use the new secret: run `aap/verify.yml` (which
   re-syncs the `azure-rm` inventory source - that sync uses
   `azure-sp-poc` - and launches `winapp-ping`), or just re-sync the
   inventory source from the AAP UI and confirm it still lists exactly
   `vm-winapp-01`.
   ```bash
   ansible-playbook aap/verify.yml
   ```

## Rollback

If the new secret is somehow wrong (e.g. `create-aap-sp.sh --rotate` was
interrupted), the previous secret is gone from Key Vault (secret **values**
are versioned in Key Vault, but `create-aap-sp.sh` always reads/writes the
latest version) - recover by reading a prior version directly:
```bash
az keyvault secret list-versions --vault-name <kv-name> -n aap-sp-client-secret -o table
az keyvault secret show --vault-name <kv-name> -n aap-sp-client-secret --version <id> --query value -o tsv
```
then either restore that value as the current version
(`az keyvault secret set ... --value <old-value>`) or re-run
`create-aap-sp.sh --rotate` again to mint a fresh one, and repeat steps 2-4
above.

## Verification evidence (this wave, I5)

`create-aap-sp.sh --rotate` was **not** run (the instruction for this fix
wave was explicitly not to rotate the live secret). Instead:

- `ansible-playbook aap/configure.yml` (default, `aap_update_secrets`
  unset → `false`) → `changed=0`, confirming the new `update_secrets:
  "{{ aap_update_secrets }}"` wiring is still idempotent by default.
- `ansible-playbook aap/configure.yml -e aap_update_secrets=true --check
  --diff` ran cleanly against the live sandbox with no errors, exercising
  the `true` branch's templating and module calls without writing anything
  (`--check` never applies a real change). The `ansible.controller.*`
  credential/user modules do not implement fine-grained check-mode
  diffing, so their `changed` count under `--check` is not itself
  meaningful evidence either way - what matters is that the run completed
  with `aap_update_secrets` resolving to `true` and no task erroring.
- A follow-up real `ansible-playbook aap/configure.yml` (default again)
  confirmed `changed=0`, i.e. the `--check` run left no real state behind.
