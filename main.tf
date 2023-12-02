terraform {
required_providers {
aws = {
source = "hashicorp/aws"
version = "~> 5.19"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}



locals {
   availability_zones = ["us-east-1a","us-east-1b"]
}

# Creation du VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "MainVPC"
  }
}

#Define Internet Gateway
resource "aws_internet_gateway" "my_igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "my-internet-gateway"
  }
}

# Attach Internet Gateway to Subnets
resource "aws_route_table" "my_route_table" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.my_igw.id
  }
}

# Configuration sous-réseaux (deux sous-réseaux pour haute disponibilité)
resource "aws_subnet" "subnet1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = local.availability_zones[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "subnet1"
  }
  
}

resource "aws_subnet" "subnet2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = local.availability_zones[1]
  map_public_ip_on_launch = true

  tags = {
    Name = "subnet2"
  }
  
}

resource "aws_db_subnet_group" "aurora_subnet_group" {
  name = "aurora_db_subnet_group"
  description = "Allowed subnets for Aurora DB cluster instances"
  subnet_ids = [
    aws_subnet.subnet1.id,
    aws_subnet.subnet2.id,
  ]
}

# Route Table Association for Subnet1
resource "aws_route_table_association" "subnet1_association" {
  subnet_id      = aws_subnet.subnet1.id
  route_table_id = aws_route_table.my_route_table.id
}

# Route Table Association for Subnet2
resource "aws_route_table_association" "subnet2_association" {
  subnet_id      = aws_subnet.subnet2.id
  route_table_id = aws_route_table.my_route_table.id
}

# Configuration du groupe de sécurité (Security Group) pour EC2
resource "aws_security_group" "moodle_sg" {
  vpc_id = aws_vpc.main.id

  # Règle sortante permettant tout le trafic sortant
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Règles entrantes pour SSH (port 22), HTTP (port 80), et HTTPS (port 443)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["184.163.57.68/32"] # Limitez l'accès SSH à votre adresse IP uniquement
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Permettez l'accès HTTP depuis n'importe quelle adresse IP
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Permettez l'accès HTTPS depuis n'importe quelle adresse IP
  }
}

# Configuration ACL (Access Control List) pour le sous-réseau
resource "aws_network_acl" "moodle_acl" {
  vpc_id = aws_vpc.main.id
}

# Regles ACL pour le sous-reseau
resource "aws_network_acl_rule" "egress_rule"{
  network_acl_id = aws_network_acl.moodle_acl.id
    rule_number  = 100
    egress       = true
    rule_action  = "allow"
    cidr_block   = "0.0.0.0/0"
    protocol     = "-1"
  }

resource "aws_network_acl_rule" "ingress_rule"{
  network_acl_id = aws_network_acl.moodle_acl.id
     rule_number = 100
     egress      = false
     rule_action = "allow"
     cidr_block  = "0.0.0.0/0"
     protocol    = "-1"
  }

# Configuration AWS Elastic Load Balancer
resource "aws_lb" "moodle_lb" {
  name               = "moodle-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.moodle_sg.id]

  enable_deletion_protection = false

  enable_cross_zone_load_balancing = true

  subnets = [aws_subnet.subnet1.id, aws_subnet.subnet2.id]

  enable_http2 = true
}

# Configuration AWS EC2 Auto Scaling Group
resource "aws_autoscaling_group" "moodle_asg" {
 
  desired_capacity     = 2
  max_size             = 4
  min_size             = 1
  vpc_zone_identifier  = [aws_subnet.subnet1.id, aws_subnet.subnet2.id]
  health_check_type    = "EC2"
  health_check_grace_period = 300
  force_delete         = true
  launch_template {
    id = aws_launch_template.moodle_lt.id
  }
}


# Configuration AWS Elastic File System (EFS)
resource "aws_efs_file_system" "moodle_efs" {
  creation_token   = "moodle-efs"
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  encrypted        = true
  lifecycle_policy {
    transition_to_ia = "AFTER_7_DAYS"
  }

  tags = {
    Name = "moodle-efs"
  }
}

# Configuration des points de montage EFS pour subnet1
resource "aws_efs_mount_target" "moodle_efs_mount_target_subnet1" {
  file_system_id = aws_efs_file_system.moodle_efs.id
  subnet_id      = aws_subnet.subnet1.id
  security_groups= [aws_security_group.moodle_sg.id]
}
 

# Configuration des points de montage EFS pour subnet2          
resource "aws_efs_mount_target" "moodle_efs_mount_target_subnet2" {
  file_system_id = aws_efs_file_system.moodle_efs.id
  subnet_id      = aws_subnet.subnet2.id
  security_groups= [aws_security_group.moodle_sg.id]
}
 

# Configuration AWS Launch Template for EC2 instances
resource "aws_launch_template" "moodle_lt" {
  name           = "moodle-lt"
  image_id       =  var.ami_id
  instance_type  = "t2.micro"
  key_name       = "TP5-Key"
  block_device_mappings {
     device_name = "/dev/sda1"
     ebs {
        volume_size = 8
        volume_type = "gp2"
  }
}  

         user_data = <<-EOF
              #!/bin/bash
              echo "Hello, World!"
              apt-get update
              apt-get install -y mysql-client
              apt-get install -y nfs-common

              # Install amazon-efs-utils
              apt-get install -y amazon-efs-utils
              
              # Enable Amazon Linux Extras
              amazon-linux-extras enable -y php7.3

              # Install Apache, PHP with MySQL support, and other necessary packages
              yum install -y httpd php php-mysqlnd git php-gd php-pear php-mbstring memcached php-mcrypt php-xmlrpc php-soap php-intl php-zip php-zts php-xml

              # Start Apache and set it to start on boot
              systemctl start httpd
              systemctl enable httpd

              # Mount EFS in /etc/fstab with specific options
              EFS_MOUNT_POINT="/mnt/efs"
              mkdir -p $EFS_MOUNT_POINT
              EFS_FILE_SYSTEM_DNS_NAME="${aws_efs_file_system.moodle_efs.dns_name}"
              echo "$EFS_FILE_SYSTEM_DNS_NAME:/ $EFS_MOUNT_POINT nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 0 0" >> /etc/fstab
               
              # Additional EFS mount with specific options
              EFS_MNT_POINT_VAR="/var/moodledata-mount"
              mkdir -p $EFS_MNT_POINT_VAR
              EFS_FILE_SYSTEM_DNS_NAME_VAR="${aws_efs_file_system.moodle_efs.dns_name}"
              echo "$EFS_FILE_SYSTEM_DNS_NAME_VAR:/ $EFS_MNT_POINT_VAR nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,tls 0 0" >> /etc/fstab

              # Mount all entries in /etc/fstab
              mount -a             

              EOF
}
# Configuration AWS S3 Bucket
resource "aws_s3_bucket" "moodle_s3" {
  bucket = "moodle-s3-bucket"
 # region ="us-east-1"
}
#configuration des controles d"acces pour le bucket s3
resource "aws_s3_bucket_acl" "moodle_s3_acl" {
  bucket = aws_s3_bucket.moodle_s3.bucket
  acl    = "private"
}
  
# Configuration AWS Security Group for RDS
resource "aws_security_group" "db_security_group" {
  vpc_id = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    security_groups = [aws_security_group.moodle_sg.id] # Ajoutez votre groupe de sécurité EC2 ici
    }
  }

# Configuration AWS Aurora DB Cluster
resource "aws_rds_cluster" "moodle_db" {
  cluster_identifier       = "moodle-db-cluster"
  engine                   = "aurora-mysql"
  engine_version           = "5.7.mysql_aurora.2.03.2"
  availability_zones       = local.availability_zones
  database_name            = "moodle_db"
  master_username          = "xxxxxxxxxxx"
  master_password          = "xxxxx"
  backup_retention_period  = 7
  preferred_backup_window  = "04:00-05:00"
  db_subnet_group_name     = aws_db_subnet_group.aurora_subnet_group.name
  skip_final_snapshot      = true
  apply_immediately        = true
  vpc_security_group_ids   = [aws_security_group.db_security_group.id] 
}

resource "aws_rds_cluster_instance" "aurora_cluster_instance" {
  count = 2

  identifier = "aurora-instance-${count.index}"
  cluster_identifier = aws_rds_cluster.moodle_db.id
  engine = "aurora-mysql"
  engine_version = "5.7.mysql_aurora.2.03.2"
  instance_class = "db.t3.small"
  db_subnet_group_name = aws_db_subnet_group.aurora_subnet_group.name
  publicly_accessible = false

  lifecycle {
    create_before_destroy = true
  }
}

# Configuration du groupe de paramètres du cluster Aurora
resource "aws_rds_cluster_parameter_group" "moodle_db_cluster_param_group" {
  name        = "moodle-db-cluster-param-group"
  family      = "aurora-mysql5.7"
  description = "Parameter group for Moodle DB Cluster"

  parameter {
    name  = "instance_class"
    value = "db.t3.small"
  }
}


# Configuration AWS Elasticache
resource "aws_elasticache_cluster" "moodle_cache" {
  cluster_id           = "moodle-cache-cluster"
  engine               = "redis"
  node_type            = "cache.t2.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  subnet_group_name    = aws_elasticache_subnet_group.cache_subnet_group.name
}

# Configuration AWS Elasticache Subnet Group
resource "aws_elasticache_subnet_group" "cache_subnet_group" {
  name       = "moodle-cache-subnet-group"
  subnet_ids = [aws_subnet.subnet1.id, aws_subnet.subnet2.id]
}

