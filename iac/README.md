# Maestro IaC Guide

This folder contains everything needed to build and run Maestro with zero Docker or Terraform know-how. The `provision.sh` helper handles the Terraform workflow, asks for a few basics (container name and ports), and populates all required configuration files automatically.

## Quick Start
```sh
./iac/provision.sh
```

What happens:
1. The script checks that Docker and Terraform are installed.
2. If no settings exist yet, you are prompted for optional inputs (service repos and host ports). Answers are written to `terraform/generated.auto.tfvars`.
3. Terraform builds the Maestro image, creates the container, and prints the outputs to the terminal.

To review the plan without changing anything:
```sh
./iac/provision.sh plan
```

To tear everything down:
```sh
./iac/provision.sh destroy
```

## Tips
- Re-run `./iac/provision.sh` at any time to apply configuration changes. Terraform will only touch resources that need updates.
- Delete or edit `terraform/generated.auto.tfvars` if you want to re-run the prompts with different answers.
- The script leaves a Terraform state file in `terraform/terraform.tfstate`. Keep it safe if you want to rerun `destroy` later.
