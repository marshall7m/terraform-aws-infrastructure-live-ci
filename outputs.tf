output "metadb_endpoint" {
  value = aws_db_instance.metadb.endpoint
}

output "metadb_address" {
  value = aws_db_instance.metadb.address
}

output "metadb_username" {
  value = aws_db_instance.metadb.username
}

output "metadb_password" {
  sensitive = true
  value     = aws_db_instance.metadb.password
}

output "metadb_port" {
  value = aws_db_instance.metadb.port
}

output "metadb_name" {
  value = aws_db_instance.metadb.name
}

output "codebuild_trigger_sf_arn" {
  value = module.codebuild_trigger_sf.arn
}