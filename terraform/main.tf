terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Use default VPC
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security Groups
resource "aws_security_group" "alb" {
  name_prefix = "aman-strapi-alb-"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "aman-strapi-alb-sg" }
}

resource "aws_security_group" "ecs" {
  name_prefix = "aman-strapi-ecs-"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 1337
    to_port         = 1337
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "aman-strapi-ecs-sg" }
}

# Application Load Balancer
resource "aws_lb" "main" {
  name               = "aman-strapi-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = slice(data.aws_subnets.default.ids, 0, 2)

  tags = { Name = "aman-strapi-alb" }
}

resource "aws_lb_target_group" "main" {
  name        = "aman-strapi-tg"
  port        = 1337
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    path     = "/"
    interval = 30
    timeout  = 5
    matcher  = "200-299"
  }

  tags = { Name = "aman-strapi-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# ECR Repository
data "aws_ecr_repository" "main" {
  name = "aman-strapi-repo"
}
# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "aman-strapi-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "aman-strapi-cluster" }
}

# Use existing IAM role
locals {
  ecs_execution_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/ecsTaskExecutionRole"
}

data "aws_caller_identity" "current" {}

# CloudWatch Log Group
data "aws_cloudwatch_log_group" "ecs" {
  name = "/ecs/aman-strapi"
}

# ECS Task Definition
resource "aws_ecs_task_definition" "main" {
  family                   = "aman-strapi-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = local.ecs_execution_role_arn

  container_definitions = jsonencode([
    {
      name  = "strapi"
      image = "${aws_ecr_repository.main.repository_url}:latest"
      essential = true
      
      portMappings = [{
        containerPort = 1337
        protocol      = "tcp"
      }]

      environment = [
        { name = "NODE_ENV", value = "production" },
        { name = "DATABASE_CLIENT", value = "sqlite" },
        { name = "JWT_SECRET", value = "xjuQ7MTqUNi7BSlYPCq9pfxJJ0Tz0QadRind02+B6VY=" },
        { name = "ADMIN_JWT_SECRET", value = "YQDyUiLbVyblOWaSBYAdUQViF/CPrBZ7AKIeHXecdp0=" },
        { name = "APP_KEYS", value = "X8nSeDDOVFaiMKxGM2gyhg==,OQ8x061MRmwtnjDiAYfrOQ==,+6KZ/BQ1W6mVgzeh2zplFw==,0Q3X3lREGzouh4ebMhONKg==" },
        { name = "API_TOKEN_SALT", value = "wTJV3lwOWVR14H4QDpHbC5QM53xj6LeSkpjTpm7l0lw=" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = { Name = "aman-strapi-task" }
}

# ECS Service
resource "aws_ecs_service" "main" {
  name            = "aman-strapi-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.main.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = slice(data.aws_subnets.default.ids, 0, 2)
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.main.arn
    container_name   = "strapi"
    container_port   = 1337
  }

  depends_on = [aws_lb_listener.http]
}

# CloudWatch Dashboard
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "aman-strapi-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.main.name]
          ]
          period = 300
          region = var.aws_region
          title  = "CPU Utilization"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.main.name]
          ]
          period = 300
          region = var.aws_region
          title  = "Memory Utilization"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ECS", "RunningTaskCount", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.main.name]
          ]
          period = 60
          region = var.aws_region
          title  = "Running Tasks"
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          query   = "SOURCE '/ecs/aman-strapi' | fields @timestamp, @message | sort @timestamp desc | limit 20"
          region  = var.aws_region
          title   = "Recent Logs"
        }
      }
    ]
  })
}
