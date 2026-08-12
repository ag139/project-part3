resource "aws_sns_topic" "alerts" {
  name = "project-alerts"
}

resource "aws_sns_topic_subscription" "email_target" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
