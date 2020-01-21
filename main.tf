data "aws_subnet" "private_subnet_a" {
  id  = "${var.private_subnet_a_id}"
}

data "aws_subnet" "private_subnet_b" {
  id  = "${var.private_subnet_b_id}"
}

resource "aws_iam_role" "codebuild_role" {
  name               = "terraform_codebuild_role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codebuild.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "codebuild_role_policy" {
  role   = "terraform-codebuild-policy"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameters"
      ],
      "Resource": "arn:aws:ssm:${var.region}:${var.aws_account_id}:parameter/${var.environment}/*"
    },
    {
        "Action": [
            "s3:*"
        ],
        "Resource": "${aws_s3_bucket.pipeline_bucket.arn}/*",
        "Effect": "Allow"
    },
    {
      "Effect": "Allow",
      "Resource": [
        "*"
      ],
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateNetworkInterface",
        "ec2:DescribeDhcpOptions",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DeleteNetworkInterface",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeVpcs"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateNetworkInterfacePermission"
      ],
      "Resource": [
        "arn:aws:ec2:${var.region}:${var.aws_account_id}:network-interface/*"
      ],
      "Condition": {
        "StringEquals": {
          "ec2:Subnet": [
            "${data.aws_subnet.private_subnet_a.arn}",
            "${data.aws_subnet.private_subnet_b.arn}"
          ],
          "ec2:AuthorizedService": "codebuild.amazonaws.com"
        }
      }
    },
{
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeImages",
        "ecr:ListImages"
      ],
      "Resource": [
          "*"
      ]
    }
  ]
}
EOF
}

resource "aws_iam_role" "codepipeline_role" {
  name = "terraform_pipeline_role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codepipeline.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "terraform-pipeline-policy"
  role = "${aws_iam_role.codepipeline_role.id}"

  policy = <<EOF
{
  "Statement": [
    {
        "Action": [
            "iam:PassRole"
        ],
        "Resource": "*",
        "Effect": "Allow",
        "Condition": {
            "StringEqualsIfExists": {
                "iam:AWSServiceName": [
                    "cloudformation.amazonaws.com",
                    "elasticbeanstalk.amazonaws.com",
                    "ec2.amazonaws.com",
                    "ecs-tasks.amazonaws.com"
                ]
            }
        }
    },
    {
        "Action": [
            "codedeploy:CreateDeployment",
            "codedeploy:GetApplication",
            "codedeploy:GetApplicationRevision",
            "codedeploy:GetDeployment",
            "codedeploy:GetDeploymentConfig",
            "codedeploy:RegisterApplicationRevision"
        ],
        "Resource": "*",
        "Effect": "Allow"
    },
    {
        "Action": [
            "elasticbeanstalk:*",
            "ec2:*",
            "elasticloadbalancing:*",
            "autoscaling:*",
            "cloudwatch:*",
            "s3:*",
            "sns:*",
            "rds:*",
            "sqs:*",
            "ecs:*",
            "codebuild:*"
        ],
        "Resource": "*",
        "Effect": "Allow"
    },
    {
        "Effect": "Allow",
        "Action": [
            "servicecatalog:ListProvisioningArtifacts",
            "servicecatalog:CreateProvisioningArtifact",
            "servicecatalog:DescribeProvisioningArtifact",
            "servicecatalog:DeleteProvisioningArtifact",
            "servicecatalog:UpdateProduct"
        ],
        "Resource": "*"
    },
    {
        "Effect": "Allow",
        "Action": [
            "ecr:DescribeImages",
            "ecr:Get"
        ],
        "Resource": "*"
    }
],
"Version": "2012-10-17"
}
EOF
}

resource "aws_s3_bucket" "pipeline_bucket" {
  bucket = "terraformpipeline${random_uuid.test.result}"
  acl    = "private"

  tags = {
    Name        = "terraformpipeline"
  }
  force_destroy = "true"
}

resource "aws_codebuild_project" "codebuild_project" {
  name          = "terraform_codebuild"
  description   = "Serverless deployment pipeline for Terraform projects"
  build_timeout = "10"
  service_role  = "${aws_iam_role.codebuild_role.arn}"

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/eb-go-1.5-amazonlinux-64:2.1.3"
    type                        = "LINUX_CONTAINER"
    privileged_mode             = "true"
  }

  source {
    type            = "CODEPIPELINE"
    buildspec       = <<BUILDSPEC
version: 0.1
phases:
  install:
    commands:
      - yum -y install jq
      - cd /tmp && curl -o terraform.zip https://releases.hashicorp.com/terraform/${TerraformVersion}/terraform_${TerraformVersion}_linux_amd64.zip && echo "${TerraformSha256} terraform.zip" | sha256sum -c --quiet && unzip terraform.zip && mv terraform /usr/bin
  build:
    commands:
      - terraform remote config -backend=s3 -backend-config="bucket=${TerraformStateBucket}" -backend-config="key=terraform.tfstate"
      - terraform apply
BUILDSPEC
  }
}

resource "aws_codepipeline" "terraform_pipeline" {
  name       = "terraform-pipeline"
  role_arn   = "${aws_iam_role.codepipeline_role.arn}"

  artifact_store {
    location = "${aws_s3_bucket.pipeline_bucket.bucket}"
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["SourceOutput"]

      configuration {
        OAuthToken           = "${var.github_token}"
        Owner                = "${var.repo_owner}"
        Repo                 = "${var.app_name}"
        Branch               = "${var.branch_name}"
        PollForSourceChanges = "false"
      }
    }
  }

  stage {
    name = "InvokeTerraform"

    action {
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["SourceOutput"]
      output_artifacts = ["InvokeTerraformOutput"]

      configuration {
        ProjectName    = "${aws_codebuild_project.codebuild_project.name}"
      }
    }
  }

}
