variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "daily-dispatch-504917"
}

variable "region" {
  description = "GCP region for Cloud Run, Cloud Scheduler, and Artifact Registry"
  type        = string
  default     = "us-central1"
}

variable "drive_folder_id" {
  description = "Google Drive folder ID the daily EPUB gets uploaded to"
  type        = string
  default     = "13sJYzBSwjPr5toDAG48JqPkmjSEwgqtE"
}

variable "container_image" {
  description = "Full Artifact Registry image reference for the Cloud Run Job, e.g. us-central1-docker.pkg.dev/daily-dispatch-504917/daily-dispatch/daily-dispatch:latest. Built and pushed separately (OpenTofu doesn't build containers) via: gcloud builds submit --region=us-central1 --tag=<this value> ."
  type        = string
}

variable "schedule" {
  description = "Cron schedule (Cloud Scheduler syntax) for the daily digest run"
  type        = string
  default     = "0 6 * * *"
}

variable "schedule_timezone" {
  description = "IANA timezone for the cron schedule"
  type        = string
  default     = "America/Detroit"
}

variable "github_repo" {
  description = "GitHub repo (owner/name) allowed to deploy via Workload Identity Federation"
  type        = string
  default     = "AaronHaNasi/daily-dispatch"
}
