# Repository guidance

## Purpose and scope

This repository bootstraps an OpenShift CI/CD demonstration. It does not contain
the Spring PetClinic application or its active Tekton pipeline. The installer
imports those assets from external Git repositories into the demo's Gitea
instance, configures Pipelines-as-Code for CI, and configures Argo CD for DEV and
STAGE delivery.

Treat everything here as demo infrastructure, not as a production security or
availability baseline. The README records OpenShift GitOps 1.16 and OpenShift
Pipelines 1.18 as the last tested combination, while the installer subscribes to
the `latest` operator channels. Do not claim compatibility with a different
combination without a real, authorized cluster test.

## Repository map

- `demo.sh` and `demo.ps1` are equivalent Bash and PowerShell entry points. They
  expose `install`, `start`, `uninstall`, and `help`, with the default project
  prefix `demo`. Installation supports `router`, `file`, and `none` CA modes plus
  an optional user-provided certificate/key pair for the default Ingress
  Controller. A custom certificate uses a chain-digest-versioned Secret named
  `<prefix>-ingress-tls-<sha256-12>` by default.
- `infra/` contains the Gitea/PostgreSQL, Nexus, and SonarQube/PostgreSQL
  manifests applied to `<prefix>-cicd`.
- `config/gitea-configmap.yaml` provides the injected CA bundle and Gitea
  configuration. `@HOSTNAME` is replaced during installation.
- `config/gitea-init-taskrun.yaml` is a Tekton `TaskRun` template with embedded
  Python. It imports `cellosofia/spring-petclinic-pac` and
  `siamaksade/spring-petclinic-config`, initializes Gitea, and creates the
  Pipelines-as-Code credentials and webhook. The `@gitea-url@` and
  `@webhook-url@` placeholders must be rendered before applying or parsing it.
- `argo/` defines the Argo CD instance, permissive demo `AppProject`, and DEV and
  STAGE `Application` resources. The applications use automatic sync, prune,
  and self-heal.
- `triggers/` contains legacy Tekton Triggers resources. The current installers
  do not apply this directory; the active path is Pipelines-as-Code. Do not
  assume these resources are deployed or reactivate them incidentally.
- `docs/*.drawio` are editable diagram sources. `docs/images/` contains exported
  diagrams and screenshots referenced by the README.

There is no package manager, build artifact, repository-local CI workflow, or
unit-test suite. Tests described in the README belong to the imported PetClinic
repository, not to this checkout.

## Live-operation safety boundary

Default to offline inspection and static validation. Never run the following as
a test or without explicit authorization for the exact cluster and project
prefix:

- `./demo.sh install`, `./demo.sh start`, or `./demo.sh uninstall`;
- the equivalent `demo.ps1` commands;
- mutating `oc` commands such as `apply`, `create`, `patch`, `delete`, `label`,
  or `policy`;
- `git push` to the Gitea repositories; or
- host trust-store commands from the README.

`install` requires cluster-admin-like access. Depending on its CA mode, it can
patch `proxy/cluster`, write a CA ConfigMap, and wait for the managed trust
bundle, MachineConfigPools, and relevant ClusterOperators to stabilize. When
certificate/key options are supplied, it also writes a chain-digest-annotated TLS
Secret in `openshift-ingress` and changes the default Ingress Controller's
certificate.
It then installs operators with automatic approval, creates three namespaces
and RBAC, deploys stateful services, rotates/creates Gitea credentials, and
pushes changes to Gitea. `start` creates and pushes a real commit. `uninstall` deletes
`<prefix>-cicd`, `<prefix>-dev`, and `<prefix>-stage`, including their PVC-backed
data; it does not undo the trusted CA, TLS Secret, Ingress certificate, or
operators.

Before an authorized live run, confirm and report the output of
`oc config current-context` and `oc whoami --show-server`, the exact prefix, and
the three target namespaces. Never inspect or print Secret values as part of
that check.

## Secrets and demo-only posture

The repository intentionally contains well-known demo passwords and insecure
settings, including disabled TLS verification, broad Argo CD permissions, and
an empty webhook secret. Never replace these examples with real credentials or
reuse this posture outside an isolated demo cluster. Do not add credentials to
source, command lines, logs, generated files, diffs, or completion reports.

The embedded TaskRun currently prints credential material in some paths. This is
an existing security debt, not a pattern to copy. The installers must keep the
Pipelines-as-Code `Repository` manifest on stdin and reference the `gitea` Secret
created by the TaskRun; do not read, decode, print, or materialize its live token.
Do not enable shell tracing around credential handling.

The tracked file named ` .gitleaks.toml` starts with a literal space and also
allowlists `infra/` and `config/`. Standard Gitleaks discovery will not find it
as `.gitleaks.toml`, so never treat it as proof that secret scanning is active.

## Change invariants

- Keep `demo.sh` and `demo.ps1` functionally aligned. Mirror changes to commands,
  flags, defaults, installation order, waits, idempotency, generated resources,
  and cleanup unless a platform difference is deliberate and documented.
- Preserve Bash strict mode and quote variable expansions. Do not add GNU-only
  assumptions; TaskRun creation obtains its generated name directly from
  `oc create -o jsonpath` so it remains portable to macOS BSD userlands.
- PowerShell 5.1 is the declared target and
  `$ErrorActionPreference = "Stop"` is intentional. Do not introduce
  PowerShell Core-only APIs into shared execution paths.
- Keep installation steps idempotent with get-before-create/apply behavior.
  Prefer bounded waits, do not add new unbounded loops, and add timeouts when
  touching the existing TaskRun, Gitea, or Argo CD waits. Do not hide a newly
  critical failure with `|| true` or an empty catch block.
- `config/gitea-init-taskrun.yaml` uses `metadata.generateName`; create each
  `TaskRun` with `oc create`, not `oc apply`.
- Keep namespace selection based on the project prefix. Do not introduce new
  hard-coded `demo-*` destinations where the scripts must support another
  prefix.
- Keep placeholder names and their Bash/PowerShell substitutions synchronized.
  Validate rendered templates, not only their source text.
- Keep CA modes and Ingress TLS options in parity between both scripts. Validate
  all local files and option combinations before the first cluster mutation;
  require OpenSSL 1.1.1 or newer for user-provided files, configure only
  `IngressController/default`, and never print the private key or a rendered TLS
  Secret.
- Preserve the CA mode semantics: `router` manages the OpenShift router CA and
  keeps the historical Git TLS no-verify behavior; `file` manages the supplied
  complete CA bundle and uses it through `GIT_SSL_CAINFO`; `none` preserves both
  `proxy/cluster.spec.trustedCA` and inherited Git trust variables. When `none`
  is paired with a custom Ingress certificate, validate it against
  `openshift-config-managed/trusted-ca-bundle`.
- Allow `start` to use only the CA mode/file options as local Git TLS settings;
  it must not change cluster trust or Ingress. Scope temporary PowerShell Git
  environment changes to each invocation and restore the caller's environment.
- Enforce a strict Ingress certificate chain: non-CA leaf (`CA:FALSE`), ordered
  CA intermediates, and a self-signed root. Require the exact wildcard SAN for
  the observed default Ingress domain and a matching unencrypted private key.
- Derive the default TLS Secret as `<prefix>-ingress-tls-<sha256-12>` from the
  ordered certificate-chain digest and store the full digest in the
  `openshift-cicd-demo-certificate-chain-sha256` annotation. An explicitly named
  Secret must be new or already have the TLS type, same digest, canonical
  certificate chain, and cryptographically matching private key. Reuse a
  matching Secret without rewriting its key material, reject local TLS files
  that change after validation, and never rotate different TLS content in place
  under that name.
- `argo/tmp-argocd-app-patch.yaml` is a generated artifact. Never commit it.
  Keep the Pipelines-as-Code `Repository` manifest streamed over stdin and its
  credentials referenced from Secret objects rather than embedded or written to
  a temporary file.
- If images, operator channels, API versions, permissions, routes, PVCs, or
  external repository URLs change, review both platform scripts and update the
  README's tested configuration and behavior.
- If the CI/CD topology changes, update the relevant Draw.io source and its
  exported image together.

Follow the surrounding style: two-space YAML indentation, two-space Bash
indentation with `snake_case` functions, and four-space PowerShell indentation
with `Verb-Noun`/PascalCase functions. Keep comments useful and avoid unrelated
reformatting of large embedded YAML or Python blocks.

## Offline validation

Run the checks relevant to the files changed. These commands do not modify a
cluster:

```sh
git diff --check
bash -n demo.sh
./demo.sh help
pwsh -NoProfile -NonInteractive -File ./demo.ps1 help
```

When `yq` is available, validate ordinary manifests directly:

```sh
yq eval-all 'true' argo/*.yaml config/gitea-configmap.yaml infra/*.yaml triggers/*.yaml >/dev/null
```

The TaskRun source is intentionally not valid standalone YAML because the
unquoted URL placeholder begins with `@`. Parse a harmless rendered form:

```sh
sed -e 's#@gitea-url@#https://gitea.example.test#g' \
  -e 's#@webhook-url@#https://pipelines.example.test#g' \
  config/gitea-init-taskrun.yaml | yq eval-all 'true' - >/dev/null
```

Also parse the Python embedded in that rendered TaskRun:

```sh
sed -e 's#@gitea-url@#https://gitea.example.test#g' \
  -e 's#@webhook-url@#https://pipelines.example.test#g' \
  config/gitea-init-taskrun.yaml \
  | yq -r '.spec.taskSpec.steps[] | select(.name == "init-gitea") | .script' - \
  | python3 -c 'import ast, sys; ast.parse(sys.stdin.read())'
```

`kustomize build argo` fails in a clean checkout because
`argo/tmp-argocd-app-patch.yaml` is generated by `install` and ignored by Git.
For Argo changes, render a dummy patch with the same structure as the one in
both installers inside a temporary copy of `argo/`, build that copy, and remove
it afterward. Never run `install` merely to generate the patch.

There is no green repository-wide `yamllint` baseline. Do not present it as a
required passing gate until the existing TaskRun indentation and trailing-space
findings are fixed. Schema or end-to-end validation against OpenShift must be
reported separately and requires explicit authorization; a successful syntax
check is not proof that the installation works.

## Completion and Git hygiene

- Inspect `git status --short` and the focused diff; do not overwrite unrelated
  user changes or include generated files, `.DS_Store`, tokens, or cluster data.
- State exactly which offline checks passed and which live checks were not run.
- Do not commit, push, create a remote, or open a pull request unless explicitly
  requested.
