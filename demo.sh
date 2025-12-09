#!/bin/bash

set -e -u -o pipefail
SCRIPT_DIR="$(cd -P "$(dirname "$0")" && pwd)"
declare -r SCRIPT_DIR
declare PRJ_PREFIX="demo"
declare COMMAND="help"

valid_command() {
  local fn=$1
  shift
  [[ $(type -t "$fn") == "function" ]]
}

info() {
  printf "\n# INFO: %s\n" "$@"
}

err() {
  printf "\n# ERROR: %s\n" "$@"
  exit 1
}

wait_seconds() {
  local count=${1:-5}
  for _ in $(seq 1 "$count"); do
    echo -n "."
    sleep 1
  done
  printf "\n"
}

case "$OSTYPE" in
darwin*) PLATFORM="OSX" ;;
linux*) PLATFORM="LINUX" ;;
bsd*) PLATFORM="BSD" ;;
*) PLATFORM="UNKNOWN" ;;
esac

cross_sed() {
  if [[ "$PLATFORM" == "OSX" || "$PLATFORM" == "BSD" ]]; then
    sed -i "" "$1" "$2"
  elif [ "$PLATFORM" == "LINUX" ]; then
    sed -i "$1" "$2"
  fi
}

while (("$#")); do
  case "$1" in
  install | uninstall | start)
    COMMAND=$1
    shift
    ;;
  -p | --project-prefix)
    PRJ_PREFIX=$2
    shift 2
    ;;
  --)
    shift
    break
    ;;
  -* | --*)
    err "Error: Unsupported flag $1"
    ;;
  *)
    break
    ;;
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

wait_for_operator() {
  local subscription_name=$1
  local namespace=${2:-openshift-operators}
  local max_wait=${3:-600}
  local elapsed=0

  info "Esperando a que el operador de la subscription $subscription_name esté completamente instalado..."
  
  while [ $elapsed -lt $max_wait ]; do
    # Obtener el nombre del CSV instalado desde la subscription usando el CRD completo
    csv=$(oc get subscriptions.operators.coreos.com "$subscription_name" -n "$namespace" -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
    
    if [ -n "$csv" ] && [ "$csv" != "null" ]; then
      # Verificar que el CSV existe y está en estado Succeeded
      phase=$(oc get csv "$csv" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      
      if [ "$phase" == "Succeeded" ]; then
        info "Operador $subscription_name instalado correctamente (CSV: $csv)"
        return 0
      fi
      
      # Mostrar el estado actual si no está en Succeeded
      if [ -n "$phase" ] && [ "$phase" != "Succeeded" ]; then
        echo -n "[$phase]"
      fi
    else
      # Si aún no hay CSV instalado, verificar el estado de la subscription
      install_plan=$(oc get subscriptions.operators.coreos.com "$subscription_name" -n "$namespace" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || echo "")
      if [ -n "$install_plan" ] && [ "$install_plan" != "null" ]; then
        echo -n "[installing]"
      fi
    fi
    
    echo -n "."
    sleep 10
    elapsed=$((elapsed + 10))
  done
  
  err "Timeout esperando a que el operador $subscription_name se instale (esperado: $max_wait segundos)"
}

install_openshift_pipelines() {
  local namespace="openshift-operators"
  
  info "Instalando operador OpenShift Pipelines..."
  
  # Verificar si el namespace openshift-operators existe
  oc get ns "$namespace" >/dev/null 2>&1 || {
    info "Creando namespace $namespace"
    oc create namespace "$namespace"
  }
  
  # Verificar si ya existe una subscription usando el CRD completo
  if oc get subscriptions.operators.coreos.com openshift-pipelines-operator-rh -n "$namespace" >/dev/null 2>&1; then
    info "El operador OpenShift Pipelines ya está suscrito"
  else
    # Crear OperatorGroup si no existe (aunque openshift-operators ya debería tener uno)
    if ! oc get operatorgroup -n "$namespace" >/dev/null 2>&1; then
      cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-operators
  namespace: $namespace
spec:
  targetNamespaces: []
EOF
    fi
    
    # Crear Subscription para OpenShift Pipelines
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: $namespace
spec:
  channel: latest
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
  fi
  
  wait_for_operator "openshift-pipelines-operator-rh" "$namespace"
}

install_openshift_gitops() {
  local namespace="openshift-operators"
  
  info "Instalando operador OpenShift GitOps..."
  
  # Verificar si el namespace openshift-operators existe
  oc get ns "$namespace" >/dev/null 2>&1 || {
    info "Creando namespace $namespace"
    oc create namespace "$namespace"
  }
  
  # Verificar si ya existe una subscription usando el CRD completo
  if oc get subscriptions.operators.coreos.com openshift-gitops-operator -n "$namespace" >/dev/null 2>&1; then
    info "El operador OpenShift GitOps ya está suscrito"
  else
    # Crear OperatorGroup si no existe
    if ! oc get operatorgroup -n "$namespace" >/dev/null 2>&1; then
      cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-operators
  namespace: $namespace
spec:
  targetNamespaces: []
EOF
    fi
    
    # Crear Subscription para OpenShift GitOps
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: $namespace
spec:
  channel: latest
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
  fi
  
  wait_for_operator "openshift-gitops-operator" "$namespace"
}

wait_for_apiserver_restart() {
  local namespace=${1:-openshift-apiserver}
  local max_wait=${2:-600}
  local elapsed=0

  info "Esperando a que los pods de $namespace se reinicien después de la configuración del proxy..."
  sleep 30

  while [ $elapsed -lt $max_wait ]; do
    # Verificar que todos los pods estén Running
    running_pods=$(oc get pods -n "$namespace" -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | wc -w)
    total_pods=$(oc get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
    
    if [ "$total_pods" -eq 0 ]; then
      echo -n "."
      sleep 10
      elapsed=$((elapsed + 10))
      continue
    fi

    # Verificar que todos los pods estén Ready
    ready_pods=0
    for pod in $(oc get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      ready_status=$(oc get pod "$pod" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
      if [ "$ready_status" = "True" ]; then
        ready_pods=$((ready_pods + 1))
      fi
    done

    # Si todos los pods están Running y Ready, terminamos
    if [ "$running_pods" -eq "$total_pods" ] && [ "$ready_pods" -eq "$total_pods" ] && [ "$total_pods" -gt 0 ]; then
      info "Los pods de $namespace se han reiniciado correctamente y están listos"
      return 0
    fi

    echo -n "."
    sleep 10
    elapsed=$((elapsed + 10))
  done

  err "Timeout esperando a que los pods de $namespace se reinicien (esperado: $max_wait segundos)"
}

configure_router_ca() {
  info "Configurando el CA del router en el proxy del cluster..."

  # Verificar si el configmap ya existe y el proxy está configurado
  if oc get configmap custom-ca -n openshift-config >/dev/null 2>&1; then
    info "El configmap custom-ca ya existe, verificando si el proxy está configurado..."
    trusted_ca=$(oc get proxy/cluster -o jsonpath='{.spec.trustedCA.name}' 2>/dev/null || echo "")
    if [ "$trusted_ca" = "custom-ca" ]; then
      info "El proxy ya está configurado con el CA del router"
      return 0
    fi
  fi

  # Extraer el CA del secret router-ca
  info "Extrayendo el CA del secret router-ca..."
  ca_base64=$(oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' 2>/dev/null || echo "")
  if [ -z "$ca_base64" ]; then
    err "No se pudo obtener el secret router-ca del namespace openshift-ingress-operator"
  fi

  # Decodificar el base64 y crear archivo temporal
  tmp_ca_file=$(mktemp)
  echo "$ca_base64" | base64 -d > "$tmp_ca_file" 2>/dev/null || {
    err "Error al decodificar el CA del router"
  }

  # Crear o actualizar el configmap
  info "Creando configmap custom-ca en openshift-config..."
  oc create configmap custom-ca --from-file ca-bundle.crt="$tmp_ca_file" -n openshift-config --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1

  # Parchear el proxy/cluster
  info "Configurando el proxy/cluster para usar el CA..."
  oc patch proxy/cluster --type=merge -p '{"spec":{"trustedCA":{"name":"custom-ca"}}}' >/dev/null 2>&1

  # Limpiar archivo temporal
  rm -f "$tmp_ca_file"

  # Esperar a que los pods de openshift-apiserver se reinicien
  info "Esperando a que los pods de openshift-apiserver se reinicien..."
  wait_for_apiserver_restart "openshift-apiserver"
}

wait_for_pipelines_as_code_route() {
  local namespace=${1:-openshift-pipelines}
  local route_name="pipelines-as-code-controller"
  local max_wait=${2:-600}
  local elapsed=0

  info "Esperando a que la ruta $route_name esté disponible en el namespace $namespace..."
  
  while [ $elapsed -lt $max_wait ]; do
    # Intentar obtener la ruta primero en openshift-pipelines
    route=$(oc get route "$route_name" -n "$namespace" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -n "$route" ] && [ "$route" != "null" ]; then
      info "Ruta $route_name disponible en $namespace (host: $route)"
      return 0
    fi
    
    # Si no está en openshift-pipelines, intentar en pipelines-as-code
    if [ "$namespace" == "openshift-pipelines" ]; then
      route=$(oc get route "$route_name" -n pipelines-as-code -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
      if [ -n "$route" ] && [ "$route" != "null" ]; then
        info "Ruta $route_name disponible en pipelines-as-code (host: $route)"
        return 0
      fi
    fi
    
    echo -n "."
    sleep 10
    elapsed=$((elapsed + 10))
  done
  
  err "Timeout esperando a que la ruta $route_name esté disponible (esperado: $max_wait segundos)"
}

command.install() {
  export GIT_SSL_NO_VERIFY=true
  oc version >/dev/null 2>&1 || err "no oc binary found"

  info "Configurando CA del router en el proxy del cluster..."
  configure_router_ca

  info "Instalando operadores requeridos..."
  install_openshift_pipelines
  install_openshift_gitops
  
  info "Esperando a que la ruta pipelines-as-code-controller esté disponible..."
  wait_for_pipelines_as_code_route "openshift-pipelines"

  info "Creating namespaces $cicd_prj, $dev_prj, $stage_prj"
  oc get ns "$cicd_prj" 2>/dev/null || {
    oc new-project "$cicd_prj"
  }
  oc get ns "$dev_prj" 2>/dev/null || {
    oc new-project "$dev_prj"
  }
  oc get ns "$stage_prj" 2>/dev/null || {
    oc new-project "$stage_prj"
  }

  info "Configure service account permissions for pipeline"
  # Verificar y agregar políticas solo si no existen (idempotente)
  if ! oc get rolebinding -n "$dev_prj" 2>/dev/null | grep -q "system:serviceaccount:$cicd_prj:pipeline"; then
    oc policy add-role-to-user edit system:serviceaccount:"$cicd_prj":pipeline -n "$dev_prj" 2>/dev/null || true
  fi
  if ! oc get rolebinding -n "$stage_prj" 2>/dev/null | grep -q "system:serviceaccount:$cicd_prj:pipeline"; then
    oc policy add-role-to-user edit system:serviceaccount:"$cicd_prj":pipeline -n "$stage_prj" 2>/dev/null || true
  fi
  if ! oc get rolebinding -n "$cicd_prj" 2>/dev/null | grep -q "system:serviceaccount:$dev_prj:default"; then
    oc policy add-role-to-user system:image-puller system:serviceaccount:"$dev_prj":default -n "$cicd_prj" 2>/dev/null || true
  fi
  if ! oc get rolebinding -n "$cicd_prj" 2>/dev/null | grep -q "system:serviceaccount:$stage_prj:default"; then
    oc policy add-role-to-user system:image-puller system:serviceaccount:"$stage_prj":default -n "$cicd_prj" 2>/dev/null || true
  fi

  info "Deploying CI/CD infra to $cicd_prj namespace"
  oc apply -f infra -n "$cicd_prj"
  GITEA_HOSTNAME=$(oc get route gitea -o template --template='{{.spec.host}}' -n "$cicd_prj")

  info "Initiatlizing git repository in Gitea and configuring webhooks"
  WEBHOOK_URL=$(oc get route pipelines-as-code-controller -n pipelines-as-code -o template --template="{{.spec.host}}" --ignore-not-found)
  if [ -z "$WEBHOOK_URL" ]; then
    WEBHOOK_URL=$(oc get route pipelines-as-code-controller -n openshift-pipelines -o template --template="{{.spec.host}}")
  fi

  # Crear o actualizar configmap de Gitea (idempotente)
  if ! oc get configmap gitea-config -n "$cicd_prj" >/dev/null 2>&1; then
    sed "s/@HOSTNAME/$GITEA_HOSTNAME/g" config/gitea-configmap.yaml | oc apply -f - -n "$cicd_prj"
  fi
  oc rollout status deployment/gitea -n "$cicd_prj" --timeout=5m 2>/dev/null || true
  
  # Crear taskrun siempre con oc create (tiene generateName, no se puede usar apply)
  info "Creando TaskRun para inicializar Gitea..."
  taskrun_output=$(sed "s#@webhook-url@#https://$WEBHOOK_URL#g" config/gitea-init-taskrun.yaml | sed "s#@gitea-url@#https://$GITEA_HOSTNAME#g" | oc create -f - -n "$cicd_prj" 2>&1)
  # Extraer el nombre del TaskRun creado (el output será algo como "taskrun.tekton.dev/init-gitea-xxxxx created")
  taskrun_name=$(echo "$taskrun_output" | grep -oP 'init-gitea-\S+' | head -1)
  
  if [ -z "$taskrun_name" ]; then
    # Si no se pudo extraer el nombre, intentar obtenerlo de los TaskRuns existentes
    taskrun_name=$(oc get taskrun -n "$cicd_prj" -l tekton.dev/taskRun=init-gitea --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
    if [ -z "$taskrun_name" ]; then
      # Último recurso: obtener el TaskRun más reciente que empiece con init-gitea
      taskrun_name=$(oc get taskrun -n "$cicd_prj" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[?(@.metadata.name=~"init-gitea-.*")].metadata.name}' 2>/dev/null | awk '{print $NF}' || echo "")
    fi
  fi

  if [ -z "$taskrun_name" ]; then
    err "No se pudo obtener el nombre del TaskRun creado"
  fi

  info "Esperando a que el TaskRun $taskrun_name termine su ejecución..."
  wait_seconds 20

  # Esperar a que el TaskRun termine (no esté Running)
  while true; do
    taskrun_status=$(oc get taskrun "$taskrun_name" -n "$cicd_prj" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || echo "")
    if [ "$taskrun_status" = "True" ] || [ "$taskrun_status" = "False" ]; then
      info "TaskRun $taskrun_name terminó con estado: $taskrun_status"
      break
    fi
    echo "waiting for Gitea init TaskRun to complete..."
    wait_seconds 10
  done

  echo "Waiting for source code to be imported to Gitea..."
  while true; do
    result=$(curl --write-out '%{response_code}' -k --head --silent --output /dev/null https://"$GITEA_HOSTNAME"/gitea/spring-petclinic)
    if [ "$result" == "200" ]; then
      break
    fi
    wait_seconds 10
  done

  wait_seconds 10

  sleep 10

  info "Updating pipelinerun values for the demo environment"
  tmp_dir=$(mktemp -d)
  pushd "$tmp_dir"
  # Clonar solo si el directorio no existe o está vacío
  if [ ! -d spring-petclinic ] || [ -z "$(ls -A spring-petclinic 2>/dev/null)" ]; then
    git clone https://"$GITEA_HOSTNAME"/gitea/spring-petclinic
  fi
  cd spring-petclinic
  git config user.email "openshift-pipelines@redhat.com"
  git config user.name "openshift-pipelines"
  # Verificar si ya está actualizado antes de hacer cambios
  if ! grep -q "$GITEA_HOSTNAME/gitea/spring-petclinic-config" .tekton/build.yaml 2>/dev/null; then
    grep -A 2 GIT_REPOSITORY <.tekton/build.yaml
    cross_sed "s#https://github.com/siamaksade/spring-petclinic-config#https://$GITEA_HOSTNAME/gitea/spring-petclinic-config#g" .tekton/build.yaml
    grep -A 2 GIT_REPOSITORY <.tekton/build.yaml
    git status
    git add .tekton/build.yaml
    git commit -m "Updated manifests git url" || true
    git remote remove auth-origin 2>/dev/null || true
    git remote add auth-origin https://gitea:openshift@"$GITEA_HOSTNAME"/gitea/spring-petclinic
    git push auth-origin cicd-demo || true
  else
    info "El repositorio ya está actualizado con la URL correcta"
  fi
  popd
  rm -rf "$tmp_dir"

  info "Configuring pipelines-as-code"
  # Verificar si el Repository ya existe
  if oc get repository spring-petclinic -n "$cicd_prj" >/dev/null 2>&1; then
    info "El Repository pipelines-as-code ya está configurado"
  else
    # Obtener el token del secret gitea que fue creado por el TaskRun
    GITEA_TOKEN=$(oc get secret gitea -n "$cicd_prj" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -z "$GITEA_TOKEN" ]; then
      err "No se pudo obtener el token de Gitea del secret. El TaskRun debe haber fallado."
    fi

    cat <<EOF >/tmp/tmp-pac-repository.yaml
---
apiVersion: "pipelinesascode.tekton.dev/v1alpha1"
kind: Repository
metadata:
  name: spring-petclinic
  namespace: "$cicd_prj"
spec:
  url: https://$GITEA_HOSTNAME/gitea/spring-petclinic
  git_provider:
    user: git
    url: https://$GITEA_HOSTNAME
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
  token: $GITEA_TOKEN
  webhook: ""
EOF
    oc apply -f /tmp/tmp-pac-repository.yaml -n "$cicd_prj"
    rm -f /tmp/tmp-pac-repository.yaml
  fi

  wait_seconds 10

  info "Configure Argo CD"

  cat <<EOF >argo/tmp-argocd-app-patch.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dev-spring-petclinic
spec:
  destination:
    namespace: "$dev_prj"
  source:
    repoURL: https://$GITEA_HOSTNAME/gitea/spring-petclinic-config
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: stage-spring-petclinic
spec:
  destination:
    namespace: "$stage_prj"
  source:
    repoURL: https://$GITEA_HOSTNAME/gitea/spring-petclinic-config
EOF
  oc apply -k argo -n "$cicd_prj"

  info "Wait for Argo CD route..."

  until oc get route argocd-server -n "$cicd_prj" >/dev/null 2>/dev/null; do
    wait_seconds 10
  done

  info "Grants permissions to ArgoCD instances to manage resources in target namespaces"
  # Aplicar labels solo si no existen (idempotente)
  current_label_dev=$(oc get ns "$dev_prj" -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/managed-by}' 2>/dev/null || echo "")
  if [ "$current_label_dev" != "$cicd_prj" ]; then
    oc label ns "$dev_prj" argocd.argoproj.io/managed-by="$cicd_prj" --overwrite
  fi
  current_label_stage=$(oc get ns "$stage_prj" -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/managed-by}' 2>/dev/null || echo "")
  if [ "$current_label_stage" != "$cicd_prj" ]; then
    oc label ns "$stage_prj" argocd.argoproj.io/managed-by="$cicd_prj" --overwrite
  fi

  oc project "$cicd_prj"

  cat <<-EOF

############################################################################
############################################################################

  Demo is installed! Give it a few minutes to finish deployments and then:

  1) Go to spring-petclinic Git repository in Gitea:
     https://$GITEA_HOSTNAME/gitea/spring-petclinic.git

  2) Log into Gitea with username/password: gitea/openshift

  3) Edit a file in the repository and commit to trigger the pipeline (alternatively, create a pull-request)

  4) Check the pipeline run logs in Dev Console or Tekton CLI:

    \$ opc pac logs -n $cicd_prj


  You can find further details at:

  Gitea Git Server: https://$GITEA_HOSTNAME/explore/repos
  SonarQube: https://$(oc get route sonarqube -o template --template='{{.spec.host}}' -n "$cicd_prj")
  Sonatype Nexus: https://$(oc get route nexus -o template --template='{{.spec.host}}' -n "$cicd_prj")
  Argo CD:  http://$(oc get route argocd-server -o template --template='{{.spec.host}}' -n "$cicd_prj")  [login with OpenShift credentials]

############################################################################
############################################################################
EOF
}

command.start() {
  GITEA_HOSTNAME=$(oc get route gitea -o template --template='{{.spec.host}}' -n "$cicd_prj")
  info "Pushing a change to https://$GITEA_HOSTNAME/gitea/spring-petclinic-config"
  tmp_dir=$(mktemp -d)
  pushd "$tmp_dir"
  git clone https://"$GITEA_HOSTNAME"/gitea/spring-petclinic
  cd spring-petclinic
  git config user.email "openshift-pipelines@redhat.com"
  git config user.name "openshift-pipelines"
  echo "   " >>readme.md
  git add readme.md
  git commit -m "Updated readme.md"
  git remote add auth-origin https://gitea:openshift@"$GITEA_HOSTNAME"/gitea/spring-petclinic
  git push auth-origin cicd-demo
  popd
}

command.uninstall() {
  oc delete project "$dev_prj" "$stage_prj" "$cicd_prj"
}

main() {
  local fn="command.$COMMAND"
  valid_command "$fn" || {
    err "invalid command '$COMMAND'"
  }

  cd "$SCRIPT_DIR"
  $fn
  return $?
}

main
