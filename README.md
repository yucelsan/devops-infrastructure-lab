# DevOps Infrastructure Automation Lab

![Linux](https://img.shields.io/badge/Linux-RHEL%20%7C%20Debian-lightgrey?logo=linux)
![Ansible](https://img.shields.io/badge/Ansible-Automation-black?logo=ansible)
![AWX](https://img.shields.io/badge/AWX-Automation-red)
![Kubernetes](https://img.shields.io/badge/Kubernetes-Orchestration-blue?logo=kubernetes)
![Docker](https://img.shields.io/badge/Docker-Containers-blue?logo=docker)
![Terraform](https://img.shields.io/badge/Terraform-IaC-purple?logo=terraform)
![Jenkins](https://img.shields.io/badge/Jenkins-CI%2FCD-red?logo=jenkins)
![Zabbix](https://img.shields.io/badge/Zabbix-Monitoring-darkred)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-Database-blue?logo=postgresql)
![Bash](https://img.shields.io/badge/Bash-Automation-black?logo=gnubash)

## Overview

This repository contains a collection of Bash automation, monitoring, backup, deployment and recovery tools developed as part of a personal **DevOps Infrastructure Automation Lab**.

The goal of this lab is to design and operate an environment inspired by real production infrastructure practices:

- Infrastructure automation
- Kubernetes administration
- AWX high availability and failover
- Automated service recovery
- Infrastructure monitoring
- Backup and retention strategies
- Infrastructure as Code
- CI/CD
- Linux system administration
- Application deployment
- PostgreSQL administration
- Apache / NGINX configuration
- SELinux and firewall management
- Health monitoring

The environment is used to experiment with failure scenarios, automate operational procedures and develop production-oriented DevOps practices.

> **Security notice**
>
> This repository contains a sanitized portfolio version of the original lab.
> Hostnames, usernames, application names, domains, credentials, IP addresses and organization-specific information have been removed or replaced with generic lab values.
>
> No production credentials or confidential company information are intentionally included.

---

# Architecture

The lab combines several infrastructure and DevOps technologies.

```text
                         ┌─────────────────────────┐
                         │       DevOps Lab        │
                         │      Linux Server       │
                         └────────────┬────────────┘
                                      │
             ┌────────────────────────┼────────────────────────┐
             │                        │                        │
             ▼                        ▼                        ▼
       ┌───────────┐            ┌───────────┐            ┌───────────┐
       │  Jenkins  │            │  Zabbix   │            │ Terraform │
       │   CI/CD   │            │Monitoring │            │    IaC    │
       └───────────┘            └───────────┘            └───────────┘
                                      │
                                      ▼
                         ┌─────────────────────────┐
                         │      AWX Platform       │
                         └────────────┬────────────┘
                                      │
                      ┌───────────────┴───────────────┐
                      │                               │
                      ▼                               ▼
             ┌─────────────────┐             ┌─────────────────┐
             │   AWX Cluster   │             │   AWX Cluster   │
             │      1.30       │             │      1.34       │
             │                 │             │                 │
             │ KIND/Kubernetes │             │ KIND/Kubernetes │
             └────────┬────────┘             └────────┬────────┘
                      │                               │
                      └───────────────┬───────────────┘
                                      │
                                      ▼
                              ┌──────────────┐
                              │    NGINX     │
                              │ Reverse Proxy│
                              └──────────────┘
```

The AWX architecture uses two independent Kubernetes/KIND environments.

Only one AWX cluster is intended to serve traffic at a time.

The active backend can be changed automatically by the failover mechanisms included in this repository.

---

# Repository Structure

```text
.
│
├── devops-lab-healthcheck.sh
│
├── awx/
│   ├── awx-auto-heal.sh
│   └── switch-awx.sh
│
├── backups/
│   ├── backup-awx-full.sh
│   ├── backup-awx-postgres.sh
│   └── backup-terraform.sh
│
├── monitoring/
│   └── zabbix/
│       ├── zabbix-awx-130-status.sh
│       └── zabbix-awx-134-status.sh
│
├── terraform/
│   └── generate-token-and-kubeconfig.sh
│
└── workflow/
    ├── .env.example
    ├── cleanup-workflow.sh
    ├── deploy-workflow.sh
    │
    └── database/
        └── init.example.sql
```

---

# Global Infrastructure Health Check

## `devops-lab-healthcheck.sh`

The global health-check script provides a centralized diagnostic view of the lab.

It performs checks across multiple infrastructure layers.

### System

- Hostname
- Operating system
- Kernel
- Uptime
- CPU load
- Memory usage
- Swap
- Filesystems
- Inodes

### Linux services

Checks critical systemd services and their current state.

### AWX / Kubernetes

- Active AWX cluster
- Kubernetes contexts
- KIND nodes
- AWX pods
- Kubernetes API
- Cluster exclusivity
- Container states
- AWX availability

### Containers

- Docker daemon
- Running containers
- Container health

### Reverse proxy / Web

- NGINX
- Apache
- Listening ports
- HTTP/HTTPS checks

### Databases

- PostgreSQL service
- Database connectivity
- AWX database backups

### Monitoring

- Zabbix agent
- AWX monitoring scripts
- Infrastructure status

### CI/CD

- Jenkins service
- Jenkins HTTP endpoint
- Jenkins demo repository

### Security

- SELinux
- Firewall
- TLS certificates
- Certificate expiration

### Operations

- Cron jobs
- Logrotate
- Backup freshness
- Time synchronization

The script produces a final summary allowing an administrator to quickly identify degraded infrastructure components.

---

# AWX High Availability & Failover

One of the main experiments of this lab is the operation of two AWX Kubernetes environments.

```text
                    ┌───────────────┐
                    │     NGINX     │
                    │ Reverse Proxy │
                    └───────┬───────┘
                            │
                  Active AWX backend
                            │
             ┌──────────────┴──────────────┐
             │                             │
             ▼                             ▼
      ┌──────────────┐              ┌──────────────┐
      │ AWX Cluster  │              │ AWX Cluster  │
      │     1.30     │              │     1.34     │
      └──────────────┘              └──────────────┘
```

The design prevents both clusters from being considered active simultaneously.

---

## `awx/switch-awx.sh`

This script performs controlled AWX cluster switching.

Supported operations:

```bash
./switch-awx.sh status
./switch-awx.sh old
./switch-awx.sh new
```

The script performs several operations during a switch:

1. Stops the currently active KIND environment.
2. Starts the target environment.
3. Validates Docker container states.
4. Verifies cluster exclusivity.
5. Selects the expected Kubernetes context.
6. Waits for the Kubernetes API.
7. Waits for AWX pods to become ready.
8. Updates the NGINX `proxy_pass`.
9. Validates NGINX configuration.
10. Reloads NGINX.
11. Displays the final infrastructure state.

This provides a controlled failover mechanism instead of manually starting containers and modifying the reverse proxy.

---

# AWX Auto-Healing

## `awx/awx-auto-heal.sh`

The auto-healing script continuously evaluates the state of both AWX environments through monitoring scripts.

Conceptually:

```text
                 AWX Health Check
                        │
                        ▼
              ┌───────────────────┐
              │ Cluster available?│
              └─────────┬─────────┘
                        │
             ┌──────────┴──────────┐
             │                     │
            YES                    NO
             │                     │
             ▼                     ▼
       No action required    Try preferred cluster
                                   │
                                   ▼
                              Health check
                                   │
                        ┌──────────┴──────────┐
                        │                     │
                       UP                    DOWN
                        │                     │
                        ▼                     ▼
                     Success           Fallback cluster
```

The script uses:

- File locking with `flock`
- Structured logging
- Exit codes
- AWX health validation
- Automated failover
- Fallback logic
- Post-switch validation

This makes the recovery procedure deterministic and repeatable.

---

# Zabbix Monitoring

The repository contains custom scripts designed to expose AWX health information to Zabbix.

## AWX 1.30

```text
monitoring/zabbix/zabbix-awx-130-status.sh
```

## AWX 1.34

```text
monitoring/zabbix/zabbix-awx-134-status.sh
```

Each script queries the Kubernetes API and validates the presence of critical AWX components such as:

- AWX Web
- AWX Task
- AWX Operator

Return values are intentionally simple:

```text
1 = AWX operational
0 = AWX unavailable
```

This allows the result to be directly consumed by a Zabbix item and associated trigger.

---

# Backup Strategy

The lab implements several backup levels.

```text
                     Backup Strategy
                           │
          ┌────────────────┼─────────────────┐
          │                │                 │
          ▼                ▼                 ▼
     AWX Full         PostgreSQL         Terraform
      Backup             Backup            Backup
```

---

## Full AWX Backup

### `backups/backup-awx-full.sh`

Creates a complete AWX backup containing Kubernetes resources and PostgreSQL data.

Examples of captured resources:

- AWX Custom Resources
- Pods/services/resources
- Kubernetes Secrets
- ConfigMaps
- Ingress
- Services
- Namespaces
- Nodes
- PostgreSQL databases
- NGINX configuration
- AWX switching script
- Kubernetes working directories

The backup process can temporarily switch AWX environments in order to back up both clusters.

The initially active cluster is restored at the end of the operation.

Archives are compressed and automatically rotated according to the configured retention policy.

---

## PostgreSQL Backup

### `backups/backup-awx-postgres.sh`

Provides more frequent database-level backups.

Features include:

- PostgreSQL custom dump format
- Multiple AWX databases
- `flock` protection against concurrent executions
- Backup logging
- File permissions
- Retention policy
- Automatic deletion of expired backups

Example scheduling strategy:

```text
02:15 every day
```

---

## Terraform Backup

### `backups/backup-terraform.sh`

Archives the Terraform workspace while excluding unnecessary or sensitive runtime content.

Excluded examples include:

```text
.git/
.terraform/
node_modules/
logs
temporary files
```

Old archives are automatically deleted according to the retention policy.

---

# Terraform & Kubernetes Authentication

## `terraform/generate-token-and-kubeconfig.sh`

This script automates Kubernetes credentials generation for Terraform.

It:

1. Switches to the first Kubernetes cluster.
2. Validates the Kubernetes namespace and ServiceAccount.
3. Generates a temporary ServiceAccount token.
4. Retrieves the Kubernetes API endpoint.
5. Retrieves the cluster CA.
6. Repeats the operation for the second cluster.
7. Generates a dedicated Terraform kubeconfig.
8. Applies restrictive permissions.
9. Validates the generated configuration.
10. Displays token TTL information.
11. Restores the expected AWX cluster state.

Generated credentials are intentionally excluded from Git.

Example:

```gitignore
*.kubeconfig
kubeconfig*
.kube/
```

---

# Workflow Application Deployment

The `workflow/` directory contains deployment automation for a PHP/PostgreSQL application.

The objective is to make application installation repeatable across multiple Linux distributions.

Supported families include:

```text
Red Hat Enterprise Linux
Rocky Linux
AlmaLinux
CentOS
Fedora

Debian
Ubuntu
```

---

## `workflow/deploy-workflow.sh`

The deployment script automates:

- Operating system detection
- Package installation
- Apache installation
- PHP installation
- PostgreSQL installation
- PostgreSQL initialization
- Database creation
- Database role creation
- SQL import
- Application deployment
- Configuration generation
- File ownership
- File permissions
- Apache VirtualHost configuration
- HTTP → HTTPS redirection
- Self-signed TLS certificate generation
- SELinux configuration
- Firewall configuration
- Application health validation

Environment-specific configuration is externalized through:

```text
.env
```

A sanitized example is provided:

```text
workflow/.env.example
```

The real `.env` file must never be committed.

---

# Workflow Cleanup

## `workflow/cleanup-workflow.sh`

Provides the reverse operation of the deployment script.

It can remove:

- PostgreSQL database
- PostgreSQL role
- Application directory
- Apache configuration
- PHP configuration
- TLS files
- Firewall rules
- SELinux port definitions
- SELinux file contexts

This makes it possible to repeatedly test:

```text
Deploy
   ↓
Test
   ↓
Destroy
   ↓
Deploy again
```

This approach is useful for validating deployment idempotency and reproducibility.

---

# CI/CD with Jenkins

Jenkins is used in the lab to experiment with CI/CD pipelines.

The environment includes pipeline stages such as:

```text
Checkout
   ↓
Build
   ↓
Test
   ↓
Package
   ↓
Archive
```

Example artifacts generated by pipelines can be archived directly by Jenkins.

The CI/CD experiments are designed to progressively integrate:

- Git
- Jenkins Pipeline
- Automated testing
- Artifact generation
- Deployment scripts
- Infrastructure automation

---

# Security Practices

Several security mechanisms are intentionally integrated into the lab.

## Secrets

Sensitive files are excluded from version control.

Examples:

```gitignore
.env
.env.*
*.key
*.pem
*.p12
*.pfx

*.kubeconfig
kubeconfig*

*secret*.yaml
*secrets*.yaml

*.tfstate
*.tfstate.*
```

No real credentials should be stored in this repository.

---

## SELinux

On Red Hat based systems, deployment automation configures appropriate SELinux contexts.

Examples:

```text
httpd_sys_content_t
httpd_sys_rw_content_t
http_port_t
```

Required booleans can also be configured for application/database communication.

---

## Firewall

Application ports can be automatically configured through:

```text
firewalld
```

or:

```text
ufw
```

depending on the detected Linux distribution.

---

## TLS

The Workflow deployment can automatically generate a self-signed certificate for lab environments.

Production environments should instead use certificates issued by a trusted internal or public Certificate Authority.

---

# Automation Principles

The scripts in this repository follow several operational principles.

### Strict Bash execution

Where appropriate:

```bash
set -Eeuo pipefail
```

or:

```bash
set -euo pipefail
```

### Concurrent execution protection

Critical jobs use:

```bash
flock
```

to prevent multiple backup or recovery processes from running simultaneously.

### Validation before success

Automation scripts verify the resulting infrastructure state rather than assuming that a successful command means the service is operational.

Examples include:

- Kubernetes API validation
- Pod readiness
- Docker container state
- HTTP response codes
- PostgreSQL connectivity
- NGINX syntax
- Apache configuration
- SELinux contexts

### Logging

Operational scripts generate logs that can later be analyzed by administrators or monitoring systems.

---

# Skills Demonstrated

This repository demonstrates practical experience with:

| Area | Technologies |
|---|---|
| Linux | RHEL, Debian, Ubuntu, systemd, Bash |
| Automation | Bash, Ansible, AWX |
| Containers | Docker, KIND |
| Orchestration | Kubernetes |
| Infrastructure as Code | Terraform |
| CI/CD | Jenkins, Git |
| Monitoring | Zabbix |
| Databases | PostgreSQL |
| Web | Apache HTTP Server, NGINX |
| Security | SELinux, TLS, firewalld, UFW |
| Backup | pg_dump, pg_dumpall, rsync, tar |
| Operations | Cron, logrotate, health checks |
| Networking | Reverse proxy, HTTP/HTTPS, ports |
| Reliability | Auto-healing, failover, validation |

---

# Engineering Objectives

This project is not intended to reproduce a complete enterprise production platform.

It is a technical lab designed to practice and demonstrate concepts commonly encountered in production environments:

- Automation instead of manual administration
- Repeatable deployments
- Infrastructure observability
- Failure detection
- Automated recovery
- Backup strategies
- Configuration externalization
- Infrastructure security
- CI/CD
- Infrastructure as Code
- High availability concepts

The scripts intentionally expose the implementation details so they can be studied, tested and improved.

---

# Future Improvements

Planned improvements for the lab include:

- [ ] Jenkins pipelines stored as code
- [ ] Automated ShellCheck validation
- [ ] CI validation for every Bash script
- [ ] Ansible-based deployment
- [ ] Terraform modules
- [ ] Centralized logging
- [ ] Prometheus metrics
- [ ] Grafana dashboards
- [ ] Automated backup restoration tests
- [ ] Kubernetes manifests / Helm examples
- [ ] Improved secrets management
- [ ] Automated integration tests
- [ ] Containerized application deployment
- [ ] CI/CD deployment into the lab
- [ ] Infrastructure architecture documentation

---

# Disclaimer

This repository is a **sanitized technical portfolio project**.

All infrastructure identifiers, organization names, hostnames, usernames, domains, addresses and credentials shown in the public repository are either fictional, anonymized or lab-specific.

The scripts should be reviewed and adapted before being used in another environment, especially in production.

---

# Author

**Serdar AYSAN**

Senior Systems & Automation / DevOps Engineer

Areas of interest:

- DevOps
- Linux
- Cloud
- Infrastructure Automation
- Kubernetes
- CI/CD
- Terraform
- Ansible / AWX
- Monitoring
- Reliability Engineering

