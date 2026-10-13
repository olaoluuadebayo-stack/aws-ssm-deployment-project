# Project 2: EC2 + AWS Systems Manager Deployment Automation

## Objective

Deploy a simple Nginx website on an Ubuntu EC2 instance and administer it using AWS Systems Manager (SSM) Run Command instead of SSH.

## Region

`us-east-1` (N. Virginia)

## Architecture

* Dedicated VPC: `10.40.0.0/16`
* Public subnet: `10.40.1.0/24`
* Internet Gateway and public route table
* One Ubuntu 24.04 LTS EC2 instance, using `t3.micro` if eligible
* Public IPv4 address for the website demo
* Security group: inbound HTTP (TCP 80) only; no inbound SSH
* EC2 IAM role with `AmazonSSMManagedInstanceCore`
* Nginx installed and webpage deployed using SSM Run Command

## Automation

Use Bash and AWS CLI scripts for setup, verification, and cleanup. Record created resource IDs in `state.env`; exclude that file from Git.

## Acceptance criteria

1. The dedicated network is created without modifying existing VPCs.
2. The EC2 instance registers as a managed node in Systems Manager.
3. An SSM command installs Nginx and deploys the webpage successfully.
4. The webpage returns a successful HTTP response.
5. No inbound SSH rule exists.
6. The README documents architecture, commands, validation, and cleanup.
7. All billable project resources are removed after testing, and cleanup is verified.

## Cost and security controls

* Do not create a NAT Gateway, load balancer, database, or VPC endpoints.
* Keep the test window short.
* Never commit credentials, `state.env`, or logs containing sensitive information.
* Run and verify the cleanup script after testing.
* Confirm no project resources remain.

## Resource ownership

Tag every created AWS resource that supports tags with `Project=aws-ssm-deployment`. Cleanup must target only resources created for this project.
