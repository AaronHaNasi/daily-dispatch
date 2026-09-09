# Daily Dispatch

A daily news digest EPUB for a Kobo Libra Colour, with no manual syncing.

## Architecture

1. **Generate** — a Google Cloud Run Job runs Calibre's `ebook-convert` against
   `daily-digest.recipe` (RSS feeds → one EPUB, `auto_cleanup` extraction).
2. **Upload** — the same job uploads the EPUB to a Google Drive folder using
   an OAuth refresh token (the destination Drive account is a personal Gmail
   account, so a service account can't write to it directly).
3. **Trigger** — Cloud Scheduler runs the job once a day.
4. **Deploy** — pushing to `main` rebuilds and redeploys the container image
   via GitHub Actions (Workload Identity Federation, no service-account keys).
5. **Retrieve** — KOReader's Cloud Storage plugin on the Kobo pulls the file
   from that Drive folder whenever it has internet.

All GCP infrastructure is defined in `infra/` with **OpenTofu**, state stored
in a GCS bucket (Terraform Cloud can't be used as an OpenTofu backend —
HashiCorp blocks non-Terraform clients from its remote-state API).

- GCP project: `daily-dispatch-504917`
- Region: `us-central1`
- Drive destination folder ID: `13sJYzBSwjPr5toDAG48JqPkmjSEwgqtE`

## One-time setup

### 1. Local tools

```sh
brew install --cask google-cloud-sdk
brew install opentofu
gcloud init
gcloud config set project daily-dispatch-504917
```

### 2. Bootstrap the OpenTofu state bucket

Done once, outside OpenTofu (a config can't create the bucket it stores its
own state in):

```sh
gcloud storage buckets create gs://daily-dispatch-504917-tofu-state \
  --project=daily-dispatch-504917 --location=us-central1 \
  --uniform-bucket-level-access
gcloud storage buckets update gs://daily-dispatch-504917-tofu-state --versioning
```

### 3. OAuth consent screen + Desktop client (manual — GCP Console)

No Terraform/OpenTofu resource covers classic "Desktop app" OAuth client
creation, so this step stays manual regardless of IaC tooling:

1. Console → **OAuth consent screen** → User type **External**.
2. Scopes: add only `https://www.googleapis.com/auth/drive.file` (non-sensitive,
   no Google review required).
3. Add yourself as a test user, verify the flow works, then **Publish app →
   In production** — required, otherwise refresh tokens expire after 7 days.
4. **Credentials → Create OAuth client ID → Desktop app**. Note the client ID
   and client secret.

### 4. Mint the Drive refresh token

```sh
pip install -r requirements-dev.txt
python3 oauth_setup.py --client-id <CLIENT_ID> --client-secret <CLIENT_SECRET>
```

This opens a browser for consent and prints a `gcloud secrets versions add`
command. Don't commit the output.

### 5. Deploy the infrastructure

```sh
cp infra/terraform.tfvars.example infra/terraform.tfvars   # edit if needed
tofu -chdir=infra init
tofu -chdir=infra apply
```

Then store the actual credential (kept out of tofu state deliberately):

```sh
printf '%s' '{"client_id":"...","client_secret":"...","refresh_token":"..."}' | \
  gcloud secrets versions add gdrive-oauth-credentials --data-file=-
```

### 6. Build and push the first image

```sh
gcloud builds submit --region=us-central1 \
  --tag=us-central1-docker.pkg.dev/daily-dispatch-504917/daily-dispatch/daily-dispatch:latest .
tofu -chdir=infra apply   # picks up the image if terraform.tfvars pointed at :latest
```

### 7. Smoke test

```sh
gcloud run jobs execute daily-dispatch --region=us-central1
```

Check Cloud Logging for the execution, then confirm the EPUB lands in the
Drive folder before trusting the daily Cloud Scheduler trigger.

### 8. Wire up GitHub Actions

After step 5's `tofu apply`, grab the outputs it needs:

```sh
tofu -chdir=infra output workload_identity_provider
tofu -chdir=infra output github_deployer_service_account
tofu -chdir=infra output github_tofu_service_account
```

Set them as repo variables (Settings → Secrets and variables → Actions →
Variables) — not secrets, since Workload Identity Federation means there's no
credential to leak:

```sh
gh variable set WIF_PROVIDER --body "<workload_identity_provider output>"
gh variable set GCP_DEPLOY_SA --body "<github_deployer_service_account output>"
gh variable set GCP_TOFU_SA --body "<github_tofu_service_account output>"
```

`GCP_DEPLOY_SA` (`daily-dispatch-deployer@...`) is scoped narrowly to
build/push/update-job and is used by the `deploy-code` job. `GCP_TOFU_SA`
(`daily-dispatch-tofu@...`) holds `roles/owner` and is used only by the
`deploy-infra` job to run `tofu plan`/`tofu apply` — kept as a separate
identity so a compromised `deploy-code` run can't reach owner-level access.
Both are impersonable only from this one repo (`WIF_PROVIDER`'s
`attribute_condition` in `infra/main.tf`).

From then on, pushing changes to `infra/**` on `main` runs `tofu apply` in
CI, and pushing changes to `Dockerfile`, `generate-dispatch.py`,
`daily-digest.recipe`, or `requirements.txt` rebuilds the image and updates
the Cloud Run Job — both via `.github/workflows/deploy.yml`.

Note the bootstrap order: `daily-dispatch-tofu` (the SA that lets CI run
`tofu apply`) is itself created *by* `tofu apply`, so the very first apply
that introduces it must still be run locally as in step 5, with your own
`gcloud` credentials. Only later infra changes get to go through CI.

### 9. KOReader on the Kobo

Cloud Storage plugin → Google Drive → point it at folder ID
`13sJYzBSwjPr5toDAG48JqPkmjSEwgqtE`.

## Local development

Test the recipe without touching GCP:

```sh
ebook-convert daily-digest.recipe output.epub
```

Test the container's headless Calibre conversion before wiring into Cloud
Run (Qt needs `QT_QPA_PLATFORM=offscreen` even for CLI-only conversion; if
that's not enough for a given feed, fall back to wrapping with `xvfb-run -a`):

```sh
docker build -t daily-dispatch .
docker run --rm daily-dispatch ebook-convert daily-digest.recipe /tmp/out.epub -vv
```

## Operational notes

- Cloud Run Job resource limits (`2 CPU / 2Gi` in `infra/main.tf`) are a
  starting guess — check actual usage in Cloud Logging after the first real
  run and tune.
- The `google_cloud_run_v2_job` resource ignores changes to the container
  image (`lifecycle.ignore_changes`) since the GitHub Actions pipeline
  updates it directly via `gcloud run jobs update` — this keeps `tofu apply`
  from fighting normal deploys.
- Cron schedule / timezone: `infra/variables.tf` (`schedule`,
  `schedule_timezone`), currently `0 6 * * *` America/Detroit.
