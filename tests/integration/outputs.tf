output "metadb_endpoint" {
  value = module.mut_infrastructure_live_ci.metadb_endpoint
}

output "metadb_username" {
  value = module.mut_infrastructure_live_ci.metadb_username
}

output "metadb_password" {
  sensitive = true
  value     = module.mut_infrastructure_live_ci.metadb_password
}

output "metadb_port" {
  value = module.mut_infrastructure_live_ci.metadb_port
}

output "metadb_name" {
  value = module.mut_infrastructure_live_ci.metadb_name
}
