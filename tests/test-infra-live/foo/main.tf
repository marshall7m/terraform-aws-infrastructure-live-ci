variable "dependency" {
    type = string
}

output "test" {
    value = var.dependency
}
