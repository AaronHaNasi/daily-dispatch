output "cloud_run_job_name" {
  value = google_cloud_run_v2_job.daily_dispatch.name
}

output "cloud_scheduler_job_name" {
  value = google_cloud_scheduler_job.daily_trigger.name
}

output "artifact_registry_repo_url" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.repository_id}"
}

output "job_runtime_service_account" {
  value = google_service_account.job_runtime.email
}

output "github_deployer_service_account" {
  description = "Paste into the GitHub Actions workflow's `service_account` field"
  value       = google_service_account.github_deployer.email
}

output "workload_identity_provider" {
  description = "Paste into the GitHub Actions workflow's `workload_identity_provider` field"
  value       = google_iam_workload_identity_pool_provider.github_repo.name
}

output "github_tofu_service_account" {
  description = "Paste into the GitHub Actions workflow's deploy-infra `service_account` field"
  value       = google_service_account.tofu_deployer.email
}
