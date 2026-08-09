data "google_project" "current" {
  project_id = var.project_id
}

# Newer GCP projects default `gcloud builds submit` to the Compute Engine
# default SA, which doesn't automatically have storage access to the
# auto-created gs://PROJECT_ID_cloudbuild staging bucket Cloud Build reads
# the uploaded source from. cloudbuild.builds.builder is the role Google's
# own docs point to for this (includes storage.objects.get/create,
# storage.buckets.get on that bucket).
resource "google_project_iam_member" "compute_default_can_build" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.builder"
  member  = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudscheduler.googleapis.com",
    "drive.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "repo" {
  project       = var.project_id
  location      = var.region
  repository_id = "daily-dispatch"
  format        = "DOCKER"

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "job_runtime" {
  project      = var.project_id
  account_id   = "daily-dispatch-runtime"
  display_name = "Daily Dispatch Cloud Run Job runtime identity"
}

resource "google_service_account" "scheduler_invoker" {
  project      = var.project_id
  account_id   = "daily-dispatch-scheduler"
  display_name = "Cloud Scheduler invoker for the daily-dispatch job"
}

# Secret container only. The credential value (client_id/client_secret/
# refresh_token JSON minted by oauth_setup.py) is added out-of-band via
#   gcloud secrets versions add gdrive-oauth-credentials --data-file=-
# so a long-lived OAuth refresh token never lands in tofu state.
resource "google_secret_manager_secret" "gdrive_oauth" {
  project   = var.project_id
  secret_id = "gdrive-oauth-credentials"

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_iam_member" "job_runtime_secret_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.gdrive_oauth.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.job_runtime.email}"
}

resource "google_cloud_run_v2_job" "daily_dispatch" {
  project             = var.project_id
  name                = "daily-dispatch"
  location            = var.region
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.job_runtime.email
      timeout         = "1800s" # 30m — generous headroom for 11 feeds x auto_cleanup extraction
      max_retries     = 1

      containers {
        image = var.container_image

        resources {
          limits = {
            cpu    = "2"
            memory = "2Gi"
          }
        }

        env {
          name = "GDRIVE_OAUTH_CREDENTIALS"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.gdrive_oauth.secret_id
              version = "latest"
            }
          }
        }

        env {
          name  = "GDRIVE_FOLDER_ID"
          value = var.drive_folder_id
        }
      }
    }
  }

  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_iam_member.job_runtime_secret_access,
  ]

  lifecycle {
    # Image is built/pushed outside OpenTofu (gcloud builds submit); avoid
    # fighting manual redeploys that bump the tag without a matching apply.
    ignore_changes = [template[0].template[0].containers[0].image]
  }
}

# Verified against Google's own terraform-docs-samples
# (run/jobs_execute_jobs_on_schedule) and the Cloud Scheduler HTTP-target-auth
# docs: the invoker SA just needs roles/run.invoker scoped to this job, and
# Cloud Scheduler's own service agent (auto-granted on API enablement) handles
# minting the OAuth token — no extra serviceAccountTokenCreator grant needed.
resource "google_cloud_run_v2_job_iam_member" "scheduler_can_invoke" {
  project  = var.project_id
  location = google_cloud_run_v2_job.daily_dispatch.location
  name     = google_cloud_run_v2_job.daily_dispatch.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler_invoker.email}"
}

resource "google_cloud_scheduler_job" "daily_trigger" {
  project   = var.project_id
  name      = "daily-dispatch-trigger"
  region    = var.region
  schedule  = var.schedule
  time_zone = var.schedule_timezone

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.daily_dispatch.name}:run"
    body        = base64encode("{}")

    headers = {
      "Content-Type" = "application/json"
    }

    oauth_token {
      service_account_email = google_service_account.scheduler_invoker.email
    }
  }

  depends_on = [
    google_project_service.apis,
    google_cloud_run_v2_job_iam_member.scheduler_can_invoke,
  ]
}

# --- GitHub Actions deploy pipeline (Workload Identity Federation) ---
#
# Keyless auth: GitHub mints a short-lived OIDC token per workflow run, GCP
# exchanges it for a service-account token via this pool/provider, scoped to
# this one repo. No service-account JSON key ever leaves GCP.

resource "google_service_account" "github_deployer" {
  project      = var.project_id
  account_id   = "daily-dispatch-deployer"
  display_name = "GitHub Actions deploy identity for daily-dispatch"
}

resource "google_artifact_registry_repository_iam_member" "deployer_can_push" {
  project    = var.project_id
  location   = google_artifact_registry_repository.repo.location
  repository = google_artifact_registry_repository.repo.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.github_deployer.email}"
}

# run.developer (not just run.invoker) so the deploy step can update the
# job's image via `gcloud run jobs update`.
resource "google_cloud_run_v2_job_iam_member" "deployer_can_update" {
  project  = var.project_id
  location = google_cloud_run_v2_job.daily_dispatch.location
  name     = google_cloud_run_v2_job.daily_dispatch.name
  role     = "roles/run.developer"
  member   = "serviceAccount:${google_service_account.github_deployer.email}"
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions Pool"

  depends_on = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github_repo" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "daily-dispatch-repo"
  display_name                       = "daily-dispatch repo provider"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }
  # Scoped to exactly this repo — no other GitHub repo can impersonate the deployer SA.
  attribute_condition = "assertion.repository == '${var.github_repo}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "github_can_impersonate_deployer" {
  service_account_id = google_service_account.github_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}
