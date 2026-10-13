# AWS Systems Manager Deployment Automation

## Project Overview

This project demonstrates how to deploy and manage a web server on Amazon EC2 using AWS Systems Manager (SSM) Run Command, without requiring inbound SSH access.

The infrastructure is provisioned and managed using Bash scripts and the AWS CLI.

## Architecture

The deployment uses:

* **Amazon VPC:** Dedicated network with CIDR `10.40.0.0/16`
* **Public subnet:** `10.40.1.0/24`
* **Internet Gateway:** Provides internet connectivity for the public subnet
* **Route table:** Routes internet-bound traffic through the Internet Gateway
* **Amazon EC2:** Ubuntu Server 24.04 LTS on a `t3.micro` instance with an 8 GiB gp3 root volume
* **Security group:** Allows inbound HTTP traffic on port 80; no inbound SSH rule
* **AWS IAM:** An EC2 instance role with `AmazonSSMManagedInstanceCore`
* **AWS Systems Manager:** Executes the web-server installation and deployment commands remotely
* **Nginx:** Serves the deployed webpage

### Deployment flow

1. Create the VPC networking resources.
2. Create and attach the IAM role and instance profile.
3. Launch the EC2 instance with the required network and IAM configuration.
4. Confirm that the instance registers as an online Systems Manager managed node.
5. Use SSM Run Command to install and start Nginx and deploy the webpage.
6. Verify the deployment over HTTP.
7. Remove project resources after testing to control costs.

## Repository Structure

```text
aws-ssm-deployment-project/
├── PROJECT_PLAN.md
├── README.md
├── setup.sh
├── verify.sh
├── destroy.sh
├── .gitignore
└── scripts/
    ├── create-iam-role.sh
    ├── launch-ec2.sh
    └── deploy-web.sh
```

## Prerequisites

* An AWS account with permission to manage the project’s VPC, EC2, IAM, and Systems Manager resources
* AWS CLI v2
* Authenticated AWS CLI credentials
* Bash and standard Linux command-line utilities
* Git for version control

The scripts target the `us-east-1` AWS Region.

## Implementation

### 1. Network provisioning

`setup.sh` creates the dedicated VPC, public subnet, Internet Gateway, route table, and security group.

Run the network verification script:

```bash
./verify.sh
```

### 2. IAM configuration

`scripts/create-iam-role.sh` creates an EC2 role and instance profile, attaches `AmazonSSMManagedInstanceCore`, and configures EC2 to assume the role.

### 3. EC2 deployment

`scripts/launch-ec2.sh` discovers the current Ubuntu Server 24.04 AMI through AWS Systems Manager Parameter Store and launches the instance with the configured subnet, security group, IAM instance profile, and root volume.

### 4. Application deployment

`scripts/deploy-web.sh` checks the managed-node status and uses SSM Run Command to install Nginx, publish the webpage, and validate the service.

No inbound SSH rule is needed for the deployment workflow.

## Verification Results

The deployment passed the following checks:

| Check                            | Result     |
| -------------------------------- | ---------- |
| EC2 managed-node status          | Online     |
| Operating system reported by SSM | Ubuntu     |
| SSM deployment command           | Success    |
| Command response code            | 0          |
| Nginx configuration test         | Successful |
| Nginx service status             | Active     |
| HTTP response                    | `200 OK`   |
| Deployed page content            | Verified   |

The HTTP response and webpage content were checked from the client using `curl`.

## Security Considerations

* Inbound security-group access is restricted to HTTP on port 80 for the demonstration.
* No inbound SSH access is configured.
* Systems Manager provides the remote command-execution mechanism.
* The EC2 role uses the AWS-managed `AmazonSSMManagedInstanceCore` policy.
* The instance has a public IPv4 address for the HTTP demonstration. A production deployment should evaluate whether a public address is necessary and consider a load balancer, private application instances, and appropriate network endpoints or outbound connectivity.
* `state.env` contains resource identifiers and local deployment state. It must not be committed to version control.

## Cost Management

This is a learning project, not a continuously running service. EC2 runtime, public IPv4 usage, and other provisioned resources can incur charges.

After verification and documentation:

1. Terminate the EC2 instance.
2. Remove the IAM instance profile and role created for the project.
3. Delete the project security group, route table, Internet Gateway, subnet, and VPC.
4. Verify that the project has no remaining billable resources.

Always check the actual AWS resource state after cleanup. A cleanup script completing does not, by itself, prove that every resource was removed.

## Limitations

* The deployment is a single-instance demonstration, not a highly available architecture.
* The webpage is served over HTTP, without TLS.
* The project does not include a load balancer, autoscaling, a database, or a production monitoring stack.
* The public IPv4 address is intended only for this demonstration.

## Lessons Demonstrated

* Separating network provisioning, IAM configuration, compute deployment, and application deployment into scripts.
* Using IAM roles instead of embedding AWS credentials on an instance.
* Managing an EC2 instance through Systems Manager without inbound SSH access.
* Discovering a current Ubuntu AMI dynamically rather than hardcoding an AMI ID.
* Verifying application behavior from both AWS service status and an external HTTP request.
* Treating resource cleanup as part of the deployment lifecycle.

## Project Status

The initial deployment and core verification checks have passed. Final documentation, GitHub publication, and AWS resource cleanup are the remaining completion steps.
