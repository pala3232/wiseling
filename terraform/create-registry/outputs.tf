output "ecr_repo_url" {
  value = { for k, v in aws_ecr_repository.wiseling-ecr-repo : k => v.repository_url }
}