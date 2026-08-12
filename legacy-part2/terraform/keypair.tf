resource "aws_key_pair" "main" {
  key_name   = var.key_name
  public_key = file("~/.ssh/project-key.pub")
}
