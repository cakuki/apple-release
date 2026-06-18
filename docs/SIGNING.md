# Signing & secrets

How **Atelier** signs Apple-platform builds, where the secrets live, and how to rotate them.

`apple-release` is the code-only hub: it holds the shared Fastlane lanes and the reusable
[`apple-release.yml`](../.github/workflows/apple-release.yml) release workflow. Signing assets
(distribution cert + App Store provisioning profiles) are **not** stored here — they live,
fastlane-`match`-encrypted, in the private **`cakuki/ios-signing`** repo. CI consumes them
**read-only**.

## The five secrets

The reusable workflow (`apple-release.yml`) declares these as `secrets:` and the consuming app's
`release.yml` passes them with `secrets: inherit`. They are the only signing inputs CI needs:

| Secret | What it is | Used by |
| --- | --- | --- |
| `ASC_KEY_P8_BASE64` | base64 of the App Store Connect API key `.p8` | `app_store_connect_api_key` (upload + build-number lookup) |
| `ASC_KEY_ID` | the ASC API key's Key ID | same |
| `ASC_ISSUER_ID` | the ASC API issuer UUID | same |
| `MATCH_PASSWORD` | passphrase that decrypts the `ios-signing` repo | `match --readonly` |
| `MATCH_GIT_PRIVATE_KEY` | private half of the **read-only** SSH deploy key for `cakuki/ios-signing` | `webfactory/ssh-agent`, then `git clone` of the signing repo |

### Where the secrets live (current layout)

`cakuki` is a **user account, not an organization**, so there are **no org-level Actions
secrets**. The reusable workflow runs with `secrets: inherit`, which means each of the five
secrets is set **per consuming-app repo** (the repo whose `release.yml` calls
`apple-release.yml@v1`). The `apple-release` hub repo itself holds **no** Actions secrets — it
only ships code. When you rotate a secret you must update it in **every consuming-app repo**;
`gh secret set` commands below take an explicit `--repo <owner>/<app-repo>` for that reason.

> List a repo's secrets to see what's set:
> ```sh
> gh secret list --repo <owner>/<app-repo>
> ```

### Deploy-key read-only status (verified)

The CI deploy key on `cakuki/ios-signing` was verified read-only on 2026-06-18:

```
$ gh repo deploy-key list --repo cakuki/ios-signing
154566757  ci-readonly-match  read-only  ssh-ed25519 AAAA…WxPIO  2026-06-15T23:04:52Z
```

The single key (`ci-readonly-match`) carries the `read-only` flag — CI can clone/decrypt the
signing repo but **cannot push** to it. This is the desired least-privilege posture: only the
owner-run [`scripts/seed-signing.sh`](../scripts/seed-signing.sh), using a personal write key + an
Admin ASC API key, ever writes to `ios-signing`. Re-run the `deploy-key list` check after any
rotation to confirm the replacement key is still `read-only`.

> The owner-gated split that isolates the write path (a separate seed-time identity) is tracked
> as EPIC-09 slice 2 (`cakuki/atelier#9`) — out of scope here; this runbook stays read-only on
> the CI side and does not duplicate that design.

---

## Rotation runbook

Routine rotation keeps blast radius small. Each procedure is ordered, copy-pasteable, and ends
with a **verification** step. Rotate one secret at a time and verify before moving on, so a green
build is always attributable to a known change.

Conventions used below:
- `<owner>/<app-repo>` — an `owner/repo` slug for a consuming app repo (e.g. `cakuki/MyApp`). Repeat
  the `gh secret set` for **each** consuming repo (see [layout](#where-the-secrets-live-current-layout)).
- Run `gh secret set` from a trusted machine; values are read from `stdin`/files so they never land
  in shell history.

### 1. ASC API key (`.p8`) — `ASC_KEY_P8_BASE64` / `ASC_KEY_ID` / `ASC_ISSUER_ID`

Rotate when a key is leaked, a teammate with key access leaves, or on a periodic schedule.

1. **Regenerate** in App Store Connect → **Users and Access → Integrations → App Store Connect
   API**. Create a new key (the same role as the old one — for CI uploads, **App Manager** is
   enough; the **Admin** key is only needed by `seed-signing.sh`). Download the new
   `AuthKey_<NEWKEYID>.p8` (downloadable **once**). Note the new **Key ID**; the **Issuer ID** is
   account-wide and only changes if Apple reissues it.

2. **base64-encode** the new `.p8` (the workflow sets `is_key_content_base64: true`):
   ```sh
   base64 < ~/Downloads/AuthKey_<NEWKEYID>.p8 | tr -d '\n' > /tmp/asc_p8.b64
   ```

3. **Update the GitHub secrets** in each consuming repo:
   ```sh
   gh secret set ASC_KEY_P8_BASE64 --repo <owner>/<app-repo> < /tmp/asc_p8.b64
   gh secret set ASC_KEY_ID        --repo <owner>/<app-repo> --body "<NEWKEYID>"
   gh secret set ASC_ISSUER_ID     --repo <owner>/<app-repo> --body "<ISSUER_UUID>"   # only if it changed
   ```
   Then scrub the base64 copy (the `.p8` itself is still needed for the optional dry-run in the
   next step — it is scrubbed at the end):
   ```sh
   rm -f /tmp/asc_p8.b64
   ```

4. **Verify** — trigger a CI run that exercises the key. A full `beta` run is the strongest
   check; the cheapest is the TestFlight build-number lookup the `beta` lane already performs via
   `latest_testflight_build_number(api_key: …)`. Re-run the app's release workflow (or push a
   `v*` tag) and confirm the run authenticates and the build uploads. Locally you can dry-run the
   auth path:
   ```sh
   ASC_KEY_ID=<NEWKEYID> ASC_ISSUER_ID=<ISSUER_UUID> \
   ASC_KEY_P8_BASE64="$(base64 < ~/Downloads/AuthKey_<NEWKEYID>.p8 | tr -d '\n')" \
   bundle exec fastlane run latest_testflight_build_number app_identifier:com.example.App
   ```

5. **Revoke** the old key in App Store Connect once the new one is confirmed working.

6. **Scrub the `.p8`** — now that verification is done, remove the downloaded key (its base64
   copy was already scrubbed in step 3):
   ```sh
   rm -f ~/Downloads/AuthKey_<NEWKEYID>.p8
   ```

### 2. `MATCH_PASSWORD`

This is the symmetric passphrase that encrypts everything in `cakuki/ios-signing`. Rotating it
**re-encrypts the whole signing repo** under the new passphrase.

1. **Change the passphrase / re-encrypt** the match repo from a trusted machine. `match` rewrites
   the encrypted blobs with the new password:
   ```sh
   bundle exec fastlane match change_password \
     --git_url git@github.com:cakuki/ios-signing.git \
     --storage_mode git
   ```
   It prompts for the **old** passphrase (to decrypt) then the **new** one (to re-encrypt), and
   pushes the re-encrypted assets back to `ios-signing`. (You need **write** access to the signing
   repo for this step — i.e. your personal SSH key, **not** the CI read-only deploy key.)

2. **Update the secret** in each consuming repo. Run `gh secret set` with **no** `--body`/value so
   it prompts and reads the passphrase without it landing in shell history or the process list:
   ```sh
   gh secret set MATCH_PASSWORD --repo <owner>/<app-repo>
   # gh prompts: "? Paste your secret:" — type/paste the new passphrase (input is not echoed).
   ```
   To script it non-interactively, redirect from a file and shred it afterwards — never inline the
   value on the command line:
   ```sh
   gh secret set MATCH_PASSWORD --repo <owner>/<app-repo> < match_pw.txt && rm -P match_pw.txt
   ```

3. **Verify** that CI can still decrypt read-only. The strongest check is to **re-run an app's
   release workflow** (the `sync_signing` lane runs `match(readonly: is_ci)`, reading
   `MATCH_PASSWORD` from the repo secret) and confirm it installs the cert + profile. If you must
   check locally, read the passphrase into a variable via a no-echo prompt so it never appears on
   the command line or in shell history:
   ```sh
   read -rs MATCH_PASSWORD; export MATCH_PASSWORD   # prompts; input is not echoed
   ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_P8_BASE64=… \
   bundle exec fastlane sync_signing
   unset MATCH_PASSWORD
   ```
   A clean install of the cert + profile means the new passphrase decrypts the repo.

### 3. CI deploy key on `ios-signing` — `MATCH_GIT_PRIVATE_KEY`

The private SSH key whose public half is the **read-only** deploy key on `cakuki/ios-signing`.
CI loads it into `webfactory/ssh-agent` to clone the signing repo.

1. **Generate a new keypair** (no passphrase — it must be non-interactive in CI):
   ```sh
   ssh-keygen -t ed25519 -C "CI read-only (apple-release)" -f /tmp/ios_signing_ci -N ""
   ```
   This writes `/tmp/ios_signing_ci` (private) and `/tmp/ios_signing_ci.pub` (public).

2. **Add the new read-only deploy key**, then **remove the old one** (add first to avoid a window
   with no working key):
   ```sh
   gh repo deploy-key add /tmp/ios_signing_ci.pub \
     --repo cakuki/ios-signing --title "CI read-only (apple-release)"
   # --allow-write is intentionally OMITTED: the key MUST stay read-only.

   gh repo deploy-key list --repo cakuki/ios-signing            # note the OLD key's id
   gh repo deploy-key delete <OLD_KEY_ID> --repo cakuki/ios-signing
   ```
   > **Least privilege:** never pass `--allow-write` here. CI only ever clones/decrypts; the sole
   > writer is the owner-run `seed-signing.sh` using a separate personal key.

3. **Update the secret** — `MATCH_GIT_PRIVATE_KEY` is the **private** key, newlines and all:
   ```sh
   gh secret set MATCH_GIT_PRIVATE_KEY --repo <owner>/<app-repo> < /tmp/ios_signing_ci
   ```
   Then scrub the local keypair:
   ```sh
   rm -f /tmp/ios_signing_ci /tmp/ios_signing_ci.pub
   ```

4. **Verify** the deploy key is still read-only and that CI can clone:
   ```sh
   gh repo deploy-key list --repo cakuki/ios-signing
   # expect exactly one key, flagged `read-only`, titled "CI read-only (apple-release)"
   ```
   Then re-run an app's release workflow — the **Set up SSH agent for match** + `sync_signing`
   steps must clone `ios-signing` and install the assets. A green `sync_signing` confirms the new
   key works.

---

## See also

- [`scripts/seed-signing.sh`](../scripts/seed-signing.sh) — one-time, owner-run signing bootstrap
  (creates + stores assets with an Admin ASC key and a personal write key).
- [`.github/workflows/apple-release.yml`](../.github/workflows/apple-release.yml) — the reusable
  release workflow that consumes these secrets.
- EPIC-09 slice 2 (`cakuki/atelier#9`) — owner-gated least-privilege key split (write-path
  isolation), referenced above and intentionally not duplicated here.
