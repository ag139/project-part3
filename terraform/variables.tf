variable "aws_region" {}

variable "ami_id" {}

variable "instance_type" {}

variable "key_name" {}

variable "db_username" {}

variable "db_password" {
  sensitive = true
}

variable "bucket_name" {}

variable "alert_email" {}
