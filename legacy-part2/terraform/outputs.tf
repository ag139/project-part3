output "frontend_public_ip" {
  value = aws_instance.frontend.public_ip
}

output "backend_private_ip" {
  value = aws_instance.backend.private_ip
}

output "worker_private_ip" {
  value = aws_instance.worker.private_ip
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "s3_bucket_name" {
  value = aws_s3_bucket.project_bucket.bucket
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
