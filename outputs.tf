output "queue_db_name" {
  description = "AWS SimpleDB domanin name used for queueing PRs"
  value       = aws_simpledb_domain.queue.name
}