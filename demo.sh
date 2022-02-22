#!/bin/bash

set -e -u -o pipefail
declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PRJ_PREFIX="demo"
declare COMMAND="help"

valid_command() {
  local fn=$1; shift
  [[ $(type -t "$fn") == "function" ]]
}

info() {
    printf "\n# INFO: $@\n"
}

err() {
  printf "\n# ERROR: $1\n"
  exit 1
}

while (( "$#" )); do
  case "$1" in
    install|uninstall|start)
      COMMAND=$1
      shift
      ;;
    -p|--project-prefix)
      PRJ_PREFIX=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*|--*)
      err "Error: Unsupported flag $1"
      ;;
    *)
      break
  esac
done

declare -r dev_prj="$PRJ_PREFIX-dev"
declare -r stage_prj="$PRJ_PREFIX-stage"
declare -r cicd_prj="$PRJ_PREFIX-cicd"

command.help() {
  cat <<-EOF

  Usage:
      demo [command] [options]

  Example:
      demo install --project-prefix mydemo

  COMMANDS:
      install                        Sets up the demo and creates namespaces
      uninstall                      Deletes the demo
      start                          Starts the deploy DEV pipeline
      help                           Help about this command

  OPTIONS:
      -p|--project-prefix [string]   Prefix to be added to demo project names e.g. PREFIX-dev
EOF
}

command.install() {
  oc version >/dev/null 2>&1 || err "no oc binary found"

  info "Creating namespaces $cicd_prj, $dev_prj, $stage_prj"
  oc get ns $cicd_prj 2>/dev/null  || {
    oc new-project $cicd_prj
  }
  oc get ns $dev_prj 2>/dev/null  || {
    oc new-project $dev_prj
  }
  oc get ns $stage_prj 2>/dev/null  || {
    oc new-project $stage_prj
  }

  info "Configure service account permissions for pipeline"
  oc policy add-role-to-user edit system:serviceaccount:$cicd_prj:pipeline -n $dev_prj
  oc policy add-role-to-user edit system:serviceaccount:$cicd_prj:pipeline -n $stage_prj
  oc policy add-role-to-user system:image-puller system:serviceaccount:$dev_prj:default -n $cicd_prj
  oc policy add-role-to-user system:image-puller system:serviceaccount:$stage_prj:default -n $cicd_prj

  info "Grants permissions to ArgoCD instances to manage resources in target namespaces"
  oc label ns $dev_prj argocd.argoproj.io/managed-by=$cicd_prj
  oc label ns $stage_prj argocd.argoproj.io/managed-by=$cicd_prj

  info "Deploying CI/CD infra to $cicd_prj namespace"
  oc apply -f infra -n $cicd_prj
  GOGS_HOSTNAME=$(oc get route gogs -o template --template='{{.spec.host}}' -n $cicd_prj)

  info "Deploying pipeline and tasks to $cicd_prj namespace"
  oc apply -f tasks -n $cicd_prj
  oc apply -f pipelines/pipeline-build-pvc.yaml -n $cicd_prj
  sed "s#https://github.com/siamaksade#http://$GOGS_HOSTNAME/gogs#g" pipelines/pipeline-build.yaml | oc apply -f - -n $cicd_prj

  oc apply -f triggers -n $cicd_prj

  info "Initiatlizing git repository in Gogs and configuring webhooks"
  sed "s/@HOSTNAME/$GOGS_HOSTNAME/g" config/gogs-configmap.yaml | oc create -f - -n $cicd_prj
  oc rollout status deployment/gogs -n $cicd_prj
  oc create -f config/gogs-init-taskrun.yaml -n $cicd_prj

  info "Configure Argo CD"
  cat << EOF > argo/tmp-argocd-app-patch.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dev-spring-petclinic
spec:
  destination:
    namespace: $dev_prj
  source:
    repoURL: http://$GOGS_HOSTNAME/gogs/spring-petclinic-config
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: stage-spring-petclinic
spec:
  destination:
    namespace: $stage_prj
  source:
    repoURL: http://$GOGS_HOSTNAME/gogs/spring-petclinic-config
EOF
  oc apply -k argo -n $cicd_prj

cat <<EOF | kubectl apply -n $cicd_prj -f -
kind: Secret
apiVersion: v1
metadata:
  name: argocd-default-cluster-config
data:
  config: $(echo -n '{"tlsClientConfig":{"insecure":false}}' | base64)
  name: $(echo -n "in-cluster" | base64)
  namespaces: $(echo -n "$cicd_prj,$dev_prj,$stage_prj" | base64)
  server: $(echo -n "https://kubernetes.default.svc" | base64)
type: Opaque
EOF

#   oc patch cm/argocd-rbac-cm -n $cicd_prj --type=merge -p '{"data":{"policy.default":"role:admin"}}'


  info "Wait for Argo CD route..."

  until oc get route argocd-server -n $cicd_prj >/dev/null 2>/dev/null
  do
    sleep 3
  done

  oc project $cicd_prj

  cat <<-EOF

############################################################################
############################################################################

  Demo is installed! Give it a few minutes to finish deployments and then:

  1) Go to spring-petclinic Git repository in Gogs:
     http://$GOGS_HOSTNAME/gogs/spring-petclinic.git

  2) Log into Gogs with username/password: gogs/gogs

  3) Edit a file in the repository and commit to trigger the pipeline

  4) Check the pipeline run logs in Dev Console or Tekton CLI:

    \$ tkn pipeline logs petclinic-build -L -f -n $cicd_prj


  You can find further details at:

  Gogs Git Server: http://$GOGS_HOSTNAME/explore/repos
  SonarQube: https://$(oc get route sonarqube -o template --template='{{.spec.host}}' -n $cicd_prj)
  Sonatype Nexus: http://$(oc get route nexus -o template --template='{{.spec.host}}' -n $cicd_prj)
  Argo CD:  http://$(oc get route argocd-server -o template --template='{{.spec.host}}' -n $cicd_prj)  [login with OpenShift credentials]

############################################################################
############################################################################
EOF
}

command.start() {
  oc create -f runs/pipeline-build-run.yaml -n $cicd_prj
}

command.uninstall() {
  oc delete project $dev_prj $stage_prj $cicd_prj
}

main() {
  local fn="command.$COMMAND"
  valid_command "$fn" || {
    err "invalid command '$COMMAND'"
  }

  cd $SCRIPT_DIR
  $fn
  return $?
}

main
