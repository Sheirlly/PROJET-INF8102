variable "region" {
  description = "AWS region"
  default     = "us-east-1" # Replace with your preferred region
}

variable "ami_id" {
  description = "Backup AMI ID for replica instances"
  # Set a default value or provide it when calling the modules
  default = "ami-053b0d53c279acc90"
}

variable "backup_ami_id" {
  description = "Backup AMI ID for replica instances"
  # Set a default value or provide it when calling the modules
  default = "ami-053b0d53c279acc90"
}
