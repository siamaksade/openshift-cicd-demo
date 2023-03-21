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

wait_seconds() {
  local count=${1:-5}
  for i in {1..$count}
  do
    echo "."
    sleep 1
  done
  printf "\n"
}

case "$OSTYPE" in
    darwin*)  PLATFORM="OSX" ;;
    linux*)   PLATFORM="LINUX" ;;
    bsd*)     PLATFORM="BSD" ;;
    *)        PLATFORM="UNKNOWN" ;;
esac

cross_sed() {
    if [[ "$PLATFORM" == "OSX" || "$PLATFORM" == "BSD" ]]; then
        sed -i "" "$1" "$2"
    elif [ "$PLATFORM" == "LINUX" ]; then
        sed -i "$1" "$2"
    fi
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

  info "Deploying CI/CD infra to $cicd_prj namespace"
  oc apply -f infra -n $cicd_prj
  GITEA_HOSTNAME=$(oc get route gitea -o template --template='{{.spec.host}}' -n $cicd_prj)

  info "Initiatlizing git repository in Gitea and configuring webhooks"
  WEBHOOK_URL=$(oc get route pipelines-as-code-controller -n pipelines-as-code -o template --template="{{.spec.host}}"  --ignore-not-found)
  if [ -z "$WEBHOOK_URL" ]; then 
      WEBHOOK_URL=$(oc get route pipelines-as-code-controller -n openshift-pipelines -o template --template="{{.spec.host}}")
  fi

  sed "s/@HOSTNAME/$GITEA_HOSTNAME/g" config/gitea-configmap.yaml | oc create -f - -n $cicd_prj
  oc rollout status deployment/gitea -n $cicd_prj
  sed "s#@webhook-url@#https://$WEBHOOK_URL#g" config/gitea-init-taskrun.yaml | oc create -f - -n $cicd_prj


  wait_seconds 20

  while oc get taskrun -n $cicd_prj | grep Running >/dev/null 2>/dev/null
  do
    echo "waiting for Gitea init..."
    wait_seconds 5
  done
  
  echo "Waiting for source code to be imported to Gitea..."
  while true; 
  do
    result=$(curl --write-out '%{response_code}' --head --silent --output /dev/null http://$GITEA_HOSTNAME/gitea/spring-petclinic)
    if [ "$result" == "200" ]; then
	    break
    fi
    wait_seconds 5
  done
  
  wait_seconds 5

  info "Updated pipelinerun values for the demo environment"
  tmp_dir=$(mktemp -d)
  pushd $tmp_dir
  git clone http://$GITEA_HOSTNAME/gitea/spring-petclinic 
  cd spring-petclinic 
  git config user.email "openshift-pipelines@redhat.com"
  git config user.name "openshift-pipelines"
  cat .tekton/build.yaml | grep -A 2 GIT_REPOSITORY
  cross_sed "s#https://github.com/siamaksade/spring-petclinic-config#http://$GITEA_HOSTNAME/gitea/spring-petclinic-config#g" .tekton/build.yaml
  cat .tekton/build.yaml | grep -A 2 GIT_REPOSITORY
  git status
  git add .tekton/build.yaml
  git commit -m "Updated manifests git url"
  git remote add auth-origin http://gitea:openshift@$GITEA_HOSTNAME/gitea/spring-petclinic
  git push auth-origin cicd-demo
  popd

  info "Configuring pipelines-as-code"
  TASKRUN_NAME=$(oc get taskrun -n $cicd_prj -o jsonpath="{.items[0].metadata.name}")
  GITEA_TOKEN=$(oc logs $TASKRUN_NAME-pod -n $cicd_prj | grep Token | sed 's/^## Token: \(.*\) ##$/\1/g')

cat << EOF > /tmp/tmp-pac-repository.yaml
---
apiVersion: "pipelinesascode.tekton.dev/v1alpha1"
kind: Repository
metadata:
  name: spring-petclinic
  namespace: $cicd_prj
spec:
  url: http://$GITEA_HOSTNAME/gitea/spring-petclinic
  git_provider:
    user: "git"
    url: http://$GITEA_HOSTNAME
    secret:
      name: "gitea"
      key: token
    webhook_secret:
      name: "gitea"
      key: "webhook"
---
apiVersion: v1
kind: Secret
metadata:
  name: gitea
  namespace: $cicd_prj
type: Opaque
stringData:
  token: "$GITEA_TOKEN"
  webhook: ""
EOF
  oc apply -f /tmp/tmp-pac-repository.yaml -n $cicd_prj 

  wait_seconds 10

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
    repoURL: http://$GITEA_HOSTNAME/gitea/spring-petclinic-config
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: stage-spring-petclinic
spec:
  destination:
    namespace: $stage_prj
  source:
    repoURL: http://$GITEA_HOSTNAME/gitea/spring-petclinic-config
EOF
  oc apply -k argo -n $cicd_prj

  info "Wait for Argo CD route..."

  until oc get route argocd-server -n $cicd_prj >/dev/null 2>/dev/null
  do
    wait_seconds 5
  done

  info "Grants permissions to ArgoCD instances to manage resources in target namespaces"
  oc label ns $dev_prj argocd.argoproj.io/managed-by=$cicd_prj
  oc label ns $stage_prj argocd.argoproj.io/managed-by=$cicd_prj

  oc project $cicd_prj

  cat <<-EOF

############################################################################
############################################################################

  Demo is installed! Give it a few minutes to finish deployments and then:

  1) Go to spring-petclinic Git repository in Gitea:
     http://$GITEA_HOSTNAME/gitea/spring-petclinic.git

  2) Log into Gitea with username/password: gitea/openshift

  3) Edit a file in the repository and commit to trigger the pipeline (alternatively, create a pull-request)

  4) Check the pipeline run logs in Dev Console or Tekton CLI:

    \$ opc pac logs -n $cicd_prj


  You can find further details at:

  Gitea Git Server: http://$GITEA_HOSTNAME/explore/repos
  SonarQube: https://$(oc get route sonarqube -o template --template='{{.spec.host}}' -n $cicd_prj)
  Sonatype Nexus: http://$(oc get route nexus -o template --template='{{.spec.host}}' -n $cicd_prj)
  Argo CD:  http://$(oc get route argocd-server -o template --template='{{.spec.host}}' -n $cicd_prj)  [login with OpenShift credentials]

############################################################################
############################################################################
EOF
}

command.start() {
  GITEA_HOSTNAME=$(oc get route gitea -o template --template='{{.spec.host}}' -n $cicd_prj)
  info "Pushing a change to http://$GITEA_HOSTNAME/gitea/spring-petclinic-config"
  tmp_dir=$(mktemp -d)
  pushd $tmp_dir
  git clone http://$GITEA_HOSTNAME/gitea/spring-petclinic 
  cd spring-petclinic 
  git config user.email "openshift-pipelines@redhat.com"
  git config user.name "openshift-pipelines"
  echo "   " >> readme.md
  git add readme.md
  git commit -m "Updated readme.md"
  git remote add auth-origin http://gitea:openshift@$GITEA_HOSTNAME/gitea/spring-petclinic
  git push auth-origin cicd-demo
  popd
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
