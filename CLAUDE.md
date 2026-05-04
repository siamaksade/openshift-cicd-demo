# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is an OpenShift CI/CD demo that implements a complete GitOps workflow using Tekton Pipelines for continuous integration and Argo CD for continuous delivery. The demo deploys a Spring Boot application (PetClinic) across DEV and STAGE environments.

**Architecture**: The demo creates three namespaces (demo-cicd, demo-dev, demo-stage) and implements a full GitOps workflow where Tekton builds container images on git commits, and Argo CD syncs deployments from git repositories using Kustomize overlays.

## Installation and Setup

The `demo.sh` script is the primary interface for managing the demo:

```bash
# Install the demo (creates namespaces and deploys all infrastructure)
./demo.sh install

# Install with custom project prefix
./demo.sh install --project-prefix mydemo

# Start a test pipeline run (pushes a change to trigger CI)
./demo.sh start

# Completely remove the demo
./demo.sh uninstall
```

**Prerequisites**: Requires OpenShift cluster with OpenShift Pipelines and OpenShift GitOps operators installed.

**Tested Configurations**:
- OpenShift GitOps 1.15, 1.20.2
- OpenShift Pipelines 1.17, 1.22.0
- ROSA (Red Hat OpenShift Service on AWS) 4.18.37

## Repository Structure

- **infra/** - Infrastructure component manifests (Gitea, Nexus, SonarQube)
- **argo/** - Argo CD configuration including ArgoCD instance, Application manifests for dev/stage environments, and Kustomize overlays
- **config/** - Gitea initialization scripts including Python TaskRun that creates repos, configures webhooks, and generates API tokens
- **triggers/** - Tekton Triggers resources (EventListener, TriggerBinding, TriggerTemplate) for the old webhook-based approach (note: this demo uses Pipelines-as-Code instead)
- **tasks/** - Custom Tekton tasks required by the pipeline:
  - `mvn-config.yaml` - Configures Maven settings.xml with Nexus and SonarQube integration
  - `git-update-deployment.yaml` - Updates Kubernetes manifests with new image digests
  - `create-promote-pull-request.yaml` - Creates pull requests for promoting changes between environments

## CI/CD Pipeline Flow

**Continuous Integration (Tekton Pipelines-as-Code)**:
1. Developer commits to `spring-petclinic` repo on Gitea (default branch: `cicd-demo`)
2. Webhook triggers Pipelines-as-Code controller
3. Pipeline executes: unit tests → code analysis (SonarQube) → build JAR → S2I container build → push to internal registry
4. Image is tagged with `[branch]-[commit-sha]` and `latest`
5. Pipeline updates Kubernetes manifests in `spring-petclinic-config` repo with the new image digest
6. Pipeline creates a pull request for promoting the change from DEV to STAGE

**Continuous Delivery (Argo CD)**:
1. Argo CD watches `spring-petclinic-config` git repository
2. On manifest changes, Argo CD syncs to DEV environment automatically
3. For STAGE promotion, merge the auto-generated PR in `spring-petclinic-config`
4. Argo CD detects the merge and syncs to STAGE environment
5. Uses Kustomize overlays for environment-specific configuration (`environments/dev` and `environments/stage`)

## Key Components

**Gitea**: Self-hosted git server that hosts two repositories:
- `spring-petclinic` - Application source code with `.tekton/build.yaml` pipeline definition
- `spring-petclinic-config` - Kubernetes manifests and Kustomize overlays

**Pipelines-as-Code**: The demo configures a `Repository` CR in the cicd namespace that links Gitea webhooks to Tekton. The pipeline definition lives in `.tekton/build.yaml` within the application repository (not in this demo repo).

**Argo CD**: Configured with OpenShift SSO integration. Maps `kubeadmin` and `ocp-admins` group to admin role. Excludes Tekton TaskRun/PipelineRun resources from sync to avoid interfering with pipeline executions.

**Service Account Permissions**: The `pipeline` service account in the cicd namespace has `edit` role in both dev and stage namespaces. Both dev and stage default service accounts can pull images from the cicd namespace.

## Important Implementation Details

**Installation Process**:
1. Creates three namespaces and configures RBAC
2. Deploys infrastructure (Gitea, Nexus, SonarQube) to cicd namespace
3. Creates custom Tekton tasks in cicd namespace
4. Runs `init-gitea-` TaskRun to clone upstream repos, create webhooks, and generate API tokens
5. Updates the cloned `spring-petclinic` repo's `.tekton/build.yaml` to reference the local `spring-petclinic-config` repo URL
6. Generates a webhook secret for secure communication between Gitea and Pipelines-as-Code (required in OpenShift Pipelines 1.22+)
7. Creates Pipelines-as-Code Repository CR and Gitea secret with webhook secret
8. Updates Gitea webhook configuration with the generated secret
9. Deploys Argo CD and creates Application resources for dev and stage

**Dynamic Configuration**: The install script uses `sed` to template in runtime values (Gitea hostname, webhook URLs) into manifests before applying them. The `tmp-argocd-app-patch.yaml` file is generated during installation and should not be manually edited.

**Platform Compatibility**: The `cross_sed()` function handles differences between macOS/BSD and Linux `sed` syntax for in-place edits.

## Monitoring Pipeline Runs

```bash
# View pipeline logs using opc (OpenShift Pipelines CLI)
opc pac logs -n demo-cicd

# Check pipeline status
oc get pipelineruns -n demo-cicd

# View Argo CD applications
oc get applications -n demo-cicd
```

## Service Credentials

- Gitea: `gitea` / `openshift`
- Nexus: `admin` / `admin123`
- SonarQube: `admin` / `sonarqube`
- Argo CD: Login with OpenShift credentials (web UI accessible via route)

## Common Modifications

When modifying infrastructure components (gitea.yaml, nexus.yaml, sonarqube.yaml), apply changes directly:
```bash
oc apply -f infra/<component>.yaml -n demo-cicd
```

When modifying Argo CD configuration, use kustomize:
```bash
oc apply -k argo -n demo-cicd
```

The actual Tekton pipeline definition is NOT in this repository—it lives in the `.tekton/build.yaml` file of the `spring-petclinic` repository that gets cloned into Gitea during installation.

## Compatibility Notes for Newer OpenShift Versions

**OpenShift Pipelines 1.22+ (Pipelines-as-Code v0.42+)**:
- Webhook secrets are now **required** for security. The empty webhook secret that worked in older versions will cause the error: `could not validate payload, check your webhook secret?: no signature has been detected`
- The installation script automatically generates a webhook secret and configures both the Kubernetes secret and the Gitea webhook
- Custom tasks must use the `cluster` resolver in pipeline definitions. The old format `taskRef: {name: task-name}` without a resolver will fail with `cannot find referenced task`

**Updating Existing Installations**:
If you installed with an older version and are experiencing webhook failures:
1. Generate a webhook secret: `WEBHOOK_SECRET=$(openssl rand -hex 20)`
2. Update the Kubernetes secret: `oc patch secret gitea -n demo-cicd --type='json' -p="[{\"op\":\"replace\",\"path\":\"/data/webhook\",\"value\":\"$(echo -n $WEBHOOK_SECRET | base64)\"}]"`
3. Update the Gitea webhook via API or delete and recreate it with the secret
4. Restart PAC controller: `oc rollout restart deployment/pipelines-as-code-controller -n openshift-pipelines`
