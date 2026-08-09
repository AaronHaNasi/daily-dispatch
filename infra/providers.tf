terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Bootstrapped once, outside of OpenTofu, via:
  #   gcloud storage buckets create gs://daily-dispatch-504917-tofu-state \
  #     --project=daily-dispatch-504917 --location=us-central1 --uniform-bucket-level-access
  #   gcloud storage buckets update gs://daily-dispatch-504917-tofu-state --versioning
  #
  # Terraform Cloud was considered but is not usable as an OpenTofu backend:
  # HashiCorp's `cloud`/remote-state API rejects non-Terraform clients, so GCS
  # is used instead — free within this project's own billing, natively
  # supports state locking, and OpenTofu adds client-side state encryption
  # on top if that's ever wanted later.
  backend "gcs" {
    bucket = "daily-dispatch-504917-tofu-state"
    prefix = "daily-dispatch/state"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
