DevOps Project - Part 2
AWS Infrastructure Automation with Terraform and Ansible

Overview
This project demonstrates AWS infrastructure automation using Terraform for infrastructure provisioning and Ansible for configuration management.

The project simulates a multi-tier environment with separated services and automated deployment.

Architecture

User → Frontend (NGINX - EC2) → Backend (Flask API - EC2)
Backend → RDS PostgreSQL
Backend → S3 Bucket
Backend → SNS Topic
Worker → Background processing service (EC2)

Architecture Components

Component | Type | Purpose
Frontend | EC2 + NGINX | HTTP entry point
Backend | EC2 + Flask | API service
Worker | EC2 | Background tasks
RDS | PostgreSQL | Database
S3 | AWS S3 | File storage
SNS | AWS SNS | Notifications
Terraform | IaC | Infrastructure provisioning
Ansible | Automation | Configuration management

Data Flow

User sends request to frontend (NGINX)
Frontend forwards request to backend service
Backend communicates with RDS PostgreSQL
Backend uses S3 for file storage
Backend sends notifications via SNS
Worker performs background processing tasks

Terraform Responsibilities

Terraform provisions:
VPC (basic configuration)
Public subnet for frontend
Private subnets for backend and worker
EC2 instances for frontend, backend and worker
Security groups
RDS PostgreSQL database
S3 bucket
SNS topic

Terraform Commands

terraform init
terraform plan
terraform apply
terraform destroy

Terraform State

Terraform state is stored locally in terraform.tfstate

Sensitive state files are excluded from GitHub using .gitignore

A sample configuration file is provided in terraform.tfvars.example

Ansible Responsibilities

Ansible configures EC2 instances after Terraform provisioning

Ansible Roles

Role | Purpose
common | System updates
nginx | Install and configure NGINX
backend | Deploy Flask backend
worker | Configure worker service

Ansible Inventory

[frontend]
<FRONTEND_PUBLIC_IP>

[backend]
<BACKEND_PRIVATE_IP>

[worker]
<WORKER_PRIVATE_IP>

Run Ansible

ansible-playbook -i inventory.ini playbook.yml

Backend Service

The backend is a Flask application that exposes REST API endpoints, communicates with PostgreSQL, uses S3 for file storage and sends notifications via SNS

Backend API Endpoints

Method | Endpoint | Description
GET | / | Health check
GET | /users | Get users
POST | /add_user | Add user
POST | /upload | Upload file

NGINX Reverse Proxy

NGINX runs on the frontend EC2 instance and forwards requests to the backend service

server {
    listen 80;

    location / {
        proxy_pass http://<BACKEND_PRIVATE_IP>:5000;
    }
}

Security Groups

Frontend Security Group allows HTTP access from the internet and SSH for management
Backend Security Group allows port 5000 only from frontend and SSH from frontend
Worker Security Group allows SSH from frontend only

Variables

Terraform variables include AWS region, instance types, database configuration, key pair name and S3 bucket name

Secrets Management

Sensitive values are excluded from GitHub and replaced with placeholders:
<DB_PASSWORD>
<RDS_ENDPOINT>
<SNS_TOPIC_ARN>

Testing

terraform output
ansible-playbook -i inventory.ini playbook.yml
curl http://<FRONTEND_PUBLIC_IP>
curl http://<FRONTEND_PUBLIC_IP>/users

Cleanup

terraform destroy

Challenges and Solutions

Challenge: Service communication between EC2 instances
Solution: Security groups and private networking

Challenge: Infrastructure automation
Solution: Separation between Terraform and Ansible

Best Practices

Infrastructure as Code with Terraform
Configuration management with Ansible
Separation of services into tiers
Secrets excluded from GitHub
Modular Ansible roles

Technologies Used

AWS EC2
AWS RDS PostgreSQL
AWS S3
AWS SNS
Terraform
Ansible
Python
Flask
NGINX
Linux
GitHub

Repository Structure

project-part2/
terraform/
provider.tf
variables.tf
outputs.tf
ec2.tf
networking.tf
security.tf
rds.tf
s3.tf
sns.tf

ansible/
inventory.ini
playbook.yml
roles/
common
nginx
backend
worker
