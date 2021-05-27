output "codepipeline_arn" {
  value = try(module.codepipeline[0].arn, null)
}

output "codepipeline_role_arn" {
  value = try(module.codepipeline[0].role_arn, null)
}

output "codebuild_arn" {
  value = try(module.codebuild[0].arn, null)
}

output "codebuild_role_arn" {
  value = try(module.codebuild[0].role_arn, null)
}

# output "bucket_arn" {
#     value = module.codepipeline.artifact_bucket_arn
# }

output "codestar_arn" {
  value = aws_codestarconnections_connection.github.arn
}