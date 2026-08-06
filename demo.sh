#!/bin/bash

set -e -u -o pipefail
set +x
SCRIPT_DIR="$(cd -P "$(dirname "$0")" && pwd)"
declare -r SCRIPT_DIR
declare -r INVOCATION_DIR="$(pwd -P)"
declare PRJ_PREFIX="demo"
declare COMMAND="help"
declare COMMAND_SET="false"
declare CA_MODE="router"
declare CA_MODE_EXPLICIT="false"
declare CA_FILE=""
declare CA_CONFIGMAP=""
declare CA_CONFIGMAP_EXPLICIT="false"
declare INGRESS_TLS_CERT=""
declare INGRESS_TLS_KEY=""
declare INGRESS_TLS_SECRET=""
declare INGRESS_TLS_SECRET_EXPLICIT="false"
declare INGRESS_CERT_SHA256=""
declare INGRESS_CERT_FILE_SHA256=""
declare INGRESS_KEY_FILE_SHA256=""
declare -r INGRESS_CONTROLLER="default"
declare -r INGRESS_CERT_ANNOTATION="openshift-cicd-demo-certificate-chain-sha256"
declare TLS_OPTIONS_EXPLICIT="false"
declare CURL_SSL_NO_REVOKE="false"

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
  local elapsed=0
  while [ "$elapsed" -lt "$count" ]; do
    echo -n "."
    sleep 1
    elapsed=$((elapsed + 1))
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
  install | uninstall | start | help)
    [[ "$COMMAND_SET" != "true" ]] ||
      err "Error: only one command can be specified"
    COMMAND=$1
    COMMAND_SET="true"
    shift
  ;;
  -p | --project-prefix)
    (($# >= 2)) && [[ "$2" != -* ]] || err "Error: $1 requires a value"
    PRJ_PREFIX=$2
    shift 2
    ;;
  --ca-mode)
    (($# >= 2)) && [[ "$2" != -* ]] || err "Error: $1 requires a value"
    CA_MODE=$2
    CA_MODE_EXPLICIT="true"
    TLS_OPTIONS_EXPLICIT="true"
    shift 2
    ;;
  --ca-file)
    (($# >= 2)) && [[ "$2" != -* ]] || err "Error: $1 requires a value"
    CA_FILE=$2
    TLS_OPTIONS_EXPLICIT="true"
    shift 2
    ;;
  --ca-configmap)
    (($# >= 2)) && [[ "$2" != -* ]] || err "Error: $1 requires a value"
    CA_CONFIGMAP=$2
    CA_CONFIGMAP_EXPLICIT="true"
    TLS_OPTIONS_EXPLICIT="true"
    shift 2
    ;;
  --ingress-tls-cert)
    (($# >= 2)) && [[ "$2" != -* ]] || err "Error: $1 requires a value"
    INGRESS_TLS_CERT=$2
    TLS_OPTIONS_EXPLICIT="true"
    shift 2
    ;;
  --ingress-tls-key)
    (($# >= 2)) && [[ "$2" != -* ]] || err "Error: $1 requires a value"
    INGRESS_TLS_KEY=$2
    TLS_OPTIONS_EXPLICIT="true"
    shift 2
    ;;
  --ingress-tls-secret)
    (($# >= 2)) && [[ "$2" != -* ]] || err "Error: $1 requires a value"
    INGRESS_TLS_SECRET=$2
    INGRESS_TLS_SECRET_EXPLICIT="true"
    TLS_OPTIONS_EXPLICIT="true"
    shift 2
    ;;
  --)
    shift
    (($# == 0)) || err "Error: unexpected argument $1"
    ;;
  -* | --*)
    err "Error: Unsupported flag $1"
    ;;
  *)
    err "Error: unexpected argument $1"
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
      demo install --ca-mode file --ca-file /secure/pki/root-ca.pem \\
        --ingress-tls-cert /secure/pki/wildcard-chain.pem \\
        --ingress-tls-key /secure/pki/wildcard.key

  COMMANDS:
      install                        Sets up the demo and creates namespaces
      uninstall                      Deletes the demo
      start                          Starts the deploy DEV pipeline
      help                           Help about this command

  OPTIONS:
      -p|--project-prefix [string]   Prefix to be added to demo project names e.g. PREFIX-dev
      --ca-mode [router|file|none]   Trusted CA/Git mode (default: router)
      --ca-file [path]               Complete CA bundle; required with --ca-mode file
      --ca-configmap [name]          Override the CA ConfigMap (install only)
      --ingress-tls-cert [path]      PEM wildcard chain (install only)
      --ingress-tls-key [path]       Matching unencrypted key (install only)
      --ingress-tls-secret [name]    Override versioned Secret (install only)
EOF
}

absolute_input_path() {
  local path=$1
  if [[ "$path" = /* ]]; then
    printf '%s' "$path"
  else
    printf '%s/%s' "$INVOCATION_DIR" "$path"
  fi
}

validate_dns_subdomain() {
  local label=$1
  local value=$2
  local component=""
  local IFS='.'
  local dns_subdomain_regex='^([a-z0-9]([-a-z0-9]*[a-z0-9])?)(\.([a-z0-9]([-a-z0-9]*[a-z0-9])?))*$'

  if ((${#value} > 253)) || [[ ! "$value" =~ $dns_subdomain_regex ]]; then
    err "$label must be a valid DNS-1123 subdomain: $value"
  fi

  for component in $value; do
    if ((${#component} > 63)); then
      err "$label contains a DNS label longer than 63 characters: $value"
    fi
  done
}

validate_dns_label() {
  local label=$1
  local value=$2
  local dns_label_regex='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'

  if ((${#value} > 63)) || [[ ! "$value" =~ $dns_label_regex ]]; then
    err "$label must be a valid DNS-1123 label with at most 63 characters: $value"
  fi
}

validate_readable_file() {
  local label=$1
  local path=$2

  if [[ ! -f "$path" || ! -r "$path" || ! -s "$path" ]]; then
    err "$label must reference a readable, non-empty file: $path"
  fi
}

require_openssl() {
  local openssl_version=""
  local major=0
  local minor=0
  local patch=0

  command -v openssl >/dev/null 2>&1 ||
    err "openssl is required to validate user-provided CA and TLS files"

  openssl_version=$(openssl version 2>/dev/null || true)
  if [[ ! "$openssl_version" =~ ^OpenSSL[[:space:]]+([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    err "OpenSSL 1.1.1 or newer is required to validate user-provided CA and TLS files"
  fi
  major=${BASH_REMATCH[1]}
  minor=${BASH_REMATCH[2]}
  patch=${BASH_REMATCH[3]}
  if ((major < 1)) ||
    ((major == 1 && minor < 1)) ||
    ((major == 1 && minor == 1 && patch < 1)); then
    err "OpenSSL 1.1.1 or newer is required to validate user-provided CA and TLS files"
  fi
}

decode_base64_to_file() {
  local encoded_value=$1
  local destination_file=$2

  if printf '%s' "$encoded_value" | base64 --decode \
    >"$destination_file" 2>/dev/null; then
    return 0
  fi
  if printf '%s' "$encoded_value" | base64 -D \
    >"$destination_file" 2>/dev/null; then
    return 0
  fi

  return 1
}

file_sha256() {
  local source_file=$1
  local digest=""

  digest=$(openssl dgst -sha256 "$source_file" 2>/dev/null |
    awk '{print $NF}' | tr '[:upper:]' '[:lower:]') || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$digest"
}

verify_supplied_ingress_files_unchanged() {
  local certificate_file_sha256=""
  local key_file_sha256=""

  [[ -r "$INGRESS_TLS_CERT" && -r "$INGRESS_TLS_KEY" ]] ||
    err "The supplied Ingress certificate or private key is no longer readable"

  certificate_file_sha256=$(file_sha256 "$INGRESS_TLS_CERT") ||
    err "Could not recheck the supplied Ingress certificate"
  key_file_sha256=$(file_sha256 "$INGRESS_TLS_KEY") ||
    err "Could not recheck the supplied Ingress private key"

  if [[ "$certificate_file_sha256" != "$INGRESS_CERT_FILE_SHA256" ||
    "$key_file_sha256" != "$INGRESS_KEY_FILE_SHA256" ]]; then
    err "The supplied Ingress certificate or private key changed after validation; restart install with stable input files"
  fi
}

validate_existing_ingress_tls_secret() {
  local validation_stage=$1
  local secret_state=""
  local secret_name=""
  local secret_type=""
  local secret_fingerprint=""

  verify_supplied_ingress_files_unchanged

  if ! secret_state=$(oc --request-timeout=15s get secret \
    "$INGRESS_TLS_SECRET" -n openshift-ingress \
    --ignore-not-found \
    -o jsonpath='{.metadata.name}{"|"}{.type}{"|"}{.metadata.annotations.openshift-cicd-demo-certificate-chain-sha256}' \
    2>/dev/null); then
    err "Could not check Secret/$INGRESS_TLS_SECRET in openshift-ingress $validation_stage"
  fi
  [[ -n "$secret_state" ]] || return 1

  IFS='|' read -r secret_name secret_type secret_fingerprint \
    <<<"$secret_state"

  if [[ "$secret_type" != "kubernetes.io/tls" ||
    "$secret_fingerprint" != "$INGRESS_CERT_SHA256" ]]; then
    err "Secret/$INGRESS_TLS_SECRET already exists without the expected TLS type and certificate-chain digest; choose an unused --ingress-tls-secret"
  fi

  if ! (
    set +x
    umask 077
    validation_dir=$(mktemp -d) || exit 1
    trap 'rm -rf -- "$validation_dir"' EXIT
    trap 'exit 1' HUP INT TERM

    existing_certificate="$validation_dir/tls.crt"
    existing_key="$validation_dir/tls.key"
    supplied_key_public="$validation_dir/supplied-key-public.der"
    existing_key_public="$validation_dir/existing-key-public.der"

    oc --request-timeout=15s get secret "$INGRESS_TLS_SECRET" \
      -n openshift-ingress -o jsonpath='{.data.tls\.crt}' \
      2>/dev/null |
      openssl base64 -d -A -out "$existing_certificate" \
        >/dev/null 2>&1 || exit 1
    [[ -s "$existing_certificate" ]] || exit 1

    oc --request-timeout=15s get secret "$INGRESS_TLS_SECRET" \
      -n openshift-ingress -o jsonpath='{.data.tls\.key}' \
      2>/dev/null |
      openssl base64 -d -A -out "$existing_key" \
        >/dev/null 2>&1 || exit 1
    [[ -s "$existing_key" ]] || exit 1

    existing_chain_sha256=$(certificate_chain_sha256 \
      "$existing_certificate" 2>/dev/null) || exit 1
    [[ "$existing_chain_sha256" == "$INGRESS_CERT_SHA256" ]] || exit 1

    openssl pkey -in "$INGRESS_TLS_KEY" -passin pass: \
      -pubout -outform DER -out "$supplied_key_public" \
      >/dev/null 2>&1 || exit 1
    openssl pkey -in "$existing_key" -passin pass: \
      -pubout -outform DER -out "$existing_key_public" \
      >/dev/null 2>&1 || exit 1
    cmp -s "$supplied_key_public" "$existing_key_public"
  ); then
    err "Secret/$INGRESS_TLS_SECRET does not contain the same canonical certificate chain and matching private key; choose an unused --ingress-tls-secret"
  fi

  return 0
}

split_pem_certificates() {
  local source_file=$1
  local destination_dir=$2

  awk -v output_dir="$destination_dir" '
    function fail() {
      invalid = 1
      exit 1
    }
    {
      line = $0
      sub(/\r$/, "", line)

      if (line == "-----BEGIN CERTIFICATE-----") {
        if (inside) {
          fail()
        }
        inside = 1
        count++
        output = sprintf("%s/cert-%04d.pem", output_dir, count)
      }

      if (inside) {
        print line > output
      } else if (line !~ /^[[:space:]]*$/) {
        fail()
      }

      if (line == "-----END CERTIFICATE-----") {
        if (!inside) {
          fail()
        }
        close(output)
        inside = 0
      }
    }
    END {
      if (invalid || inside || count == 0) {
        exit 1
      }
      print count
    }
  ' "$source_file"
}

certificate_chain_sha256() (
  local certificate_chain=$1
  local temp_dir=""
  local certificate_dir=""
  local certificate_count=""
  local certificate_file=""
  local certificate_der=""
  local combined_der=""
  local digest=""
  local index=1

  require_openssl
  temp_dir=$(mktemp -d) || return 1
  trap '[[ -z ${temp_dir:-} ]] || rm -rf -- "$temp_dir"' EXIT
  trap 'exit 1' HUP INT TERM

  certificate_dir="$temp_dir/certificates"
  mkdir "$certificate_dir" || return 1
  certificate_count=$(split_pem_certificates \
    "$certificate_chain" "$certificate_dir") || return 1
  combined_der="$temp_dir/chain.der"
  : >"$combined_der"

  while [ "$index" -le "$certificate_count" ]; do
    certificate_file=$(printf '%s/cert-%04d.pem' \
      "$certificate_dir" "$index")
    certificate_der=$(printf '%s/cert-%04d.der' \
      "$certificate_dir" "$index")
    openssl x509 -in "$certificate_file" -outform DER \
      -out "$certificate_der" >/dev/null 2>&1 || return 1
    command cat "$certificate_der" >>"$combined_der" || return 1
    index=$((index + 1))
  done

  digest=$(openssl dgst -sha256 "$combined_der" 2>/dev/null |
    awk '{print $NF}' | tr '[:upper:]' '[:lower:]')
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$digest"
)

validate_ca_bundle_with_openssl() (
  local ca_file=$1
  local temp_dir=""
  local certificate_dir=""
  local certificate_count=""
  local certificate_file=""
  local index=1

  require_openssl
  temp_dir=$(mktemp -d) || err "Could not create a CA validation directory"
  trap '[[ -z ${temp_dir:-} ]] || rm -rf -- "$temp_dir"' EXIT
  trap 'exit 1' HUP INT TERM

  certificate_dir="$temp_dir/certificates"
  mkdir "$certificate_dir"

  if ! certificate_count=$(split_pem_certificates \
    "$ca_file" "$certificate_dir"); then
    err "--ca-file must contain only complete PEM certificates"
  fi

  while [ "$index" -le "$certificate_count" ]; do
    certificate_file=$(printf '%s/cert-%04d.pem' \
      "$certificate_dir" "$index")

    if ! openssl x509 -in "$certificate_file" -noout \
      >/dev/null 2>&1; then
      err "Certificate $index in --ca-file is not valid X.509"
    fi

    if ! openssl x509 -in "$certificate_file" -noout -checkend 0 \
      >/dev/null 2>&1; then
      err "Certificate $index in --ca-file is expired"
    fi

    if ! openssl x509 -in "$certificate_file" -noout -text 2>/dev/null |
      grep -Eq 'CA:[[:space:]]*TRUE'; then
      err "Certificate $index in --ca-file is not a CA certificate"
    fi

    index=$((index + 1))
  done
)

validate_private_key_pem() {
  local key_file=$1

  if grep -Eq \
    '^-----BEGIN ENCRYPTED PRIVATE KEY-----|^Proc-Type:[[:space:]]*4,ENCRYPTED' \
    "$key_file"; then
    err "The Ingress private key must be unencrypted"
  fi

  if ! awk '
    function fail() {
      invalid = 1
      exit 1
    }
    {
      line = $0
      sub(/\r$/, "", line)

      if (line ~ /^-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----$/) {
        if (inside || blocks != 0) {
          fail()
        }
        inside = 1
        blocks++
      }

      if (!inside && line !~ /^[[:space:]]*$/) {
        fail()
      }

      if (line ~ /^-----END ([A-Z0-9]+ )?PRIVATE KEY-----$/) {
        if (!inside) {
          fail()
        }
        inside = 0
      }
    }
    END {
      if (invalid || inside || blocks != 1) {
        exit 1
      }
    }
  ' "$key_file"; then
    err "--ingress-tls-key must contain exactly one PEM private key"
  fi

  if ! openssl pkey -in "$key_file" -passin pass: -noout \
    >/dev/null 2>&1; then
    err "The Ingress private key is invalid, encrypted, or unsupported"
  fi
}

certificate_dns_sans() {
  local certificate_file=$1
  local san_output=""

  {
    if san_output=$(openssl x509 -in "$certificate_file" \
      -noout -ext subjectAltName 2>/dev/null); then
      printf '%s\n' "$san_output"
    else
      openssl x509 -in "$certificate_file" -noout -text 2>/dev/null |
        awk '
          /X509v3 Subject Alternative Name:/ {
            capture = 1
            next
          }
          capture && /^[[:space:]]+X509v3 / {
            exit
          }
          capture && /^[[:space:]]*Signature Algorithm:/ {
            exit
          }
          capture {
            print
          }
        '
    fi
  } |
    tr ',' '\n' |
    awk '
      {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        if ($0 ~ /^DNS:/) {
          print $0
        }
      }
    '
}

validate_tls_options() {
  validate_dns_label "derived CI/CD namespace" "${PRJ_PREFIX}-cicd"
  validate_dns_label "derived DEV namespace" "${PRJ_PREFIX}-dev"
  validate_dns_label "derived STAGE namespace" "${PRJ_PREFIX}-stage"

  case "$CA_MODE" in
  router | file | none) ;;
  *) err "--ca-mode must be one of: router, file, none" ;;
  esac

  if [[ "$COMMAND" != "install" && "$COMMAND" != "start" &&
    "$TLS_OPTIONS_EXPLICIT" == "true" ]]; then
    err "CA and Ingress TLS options are supported only with install or start"
  fi

  if [[ "$COMMAND" == "start" ]] &&
    [[ "$CA_CONFIGMAP_EXPLICIT" == "true" || -n "$INGRESS_TLS_CERT" ||
      -n "$INGRESS_TLS_KEY" || "$INGRESS_TLS_SECRET_EXPLICIT" == "true" ]]; then
    err "start accepts only --ca-mode and --ca-file for its local Git connection"
  fi

  if [[ "$CA_MODE" == "file" ]]; then
    [[ -n "$CA_FILE" ]] || err "--ca-file is required with --ca-mode file"
    [[ -n "$CA_CONFIGMAP" ]] || CA_CONFIGMAP="${PRJ_PREFIX}-trusted-ca"
  elif [[ -n "$CA_FILE" ]]; then
    err "--ca-file can be used only with --ca-mode file"
  elif [[ "$CA_MODE" == "router" && -z "$CA_CONFIGMAP" ]]; then
    CA_CONFIGMAP="custom-ca"
  fi

  if [[ "$CA_MODE" == "none" && "$CA_CONFIGMAP_EXPLICIT" == "true" ]]; then
    err "--ca-configmap cannot be used with --ca-mode none"
  fi

  if [[ -n "$INGRESS_TLS_CERT" && -z "$INGRESS_TLS_KEY" ]] ||
    [[ -z "$INGRESS_TLS_CERT" && -n "$INGRESS_TLS_KEY" ]]; then
    err "--ingress-tls-cert and --ingress-tls-key must be provided together"
  fi

  if [[ -z "$INGRESS_TLS_CERT" && "$INGRESS_TLS_SECRET_EXPLICIT" == "true" ]]; then
    err "--ingress-tls-secret requires a certificate/key pair"
  fi

  if [[ -n "$INGRESS_TLS_CERT" && "$CA_MODE_EXPLICIT" != "true" ]]; then
    err "Select --ca-mode file for a private CA or --ca-mode none for a public/preconfigured CA"
  fi

  if [[ -n "$INGRESS_TLS_CERT" && "$CA_MODE" == "router" ]]; then
    err "A custom Ingress certificate requires --ca-mode file or --ca-mode none"
  fi

  if [[ -n "$CA_CONFIGMAP" ]]; then
    validate_dns_subdomain "--ca-configmap" "$CA_CONFIGMAP"
  fi

  if [[ -n "$CA_FILE" ]]; then
    CA_FILE=$(absolute_input_path "$CA_FILE")
    validate_readable_file "--ca-file" "$CA_FILE"
    validate_ca_bundle_with_openssl "$CA_FILE"
  fi

  if [[ -n "$INGRESS_TLS_CERT" ]]; then
    INGRESS_TLS_CERT=$(absolute_input_path "$INGRESS_TLS_CERT")
    INGRESS_TLS_KEY=$(absolute_input_path "$INGRESS_TLS_KEY")
    validate_readable_file "--ingress-tls-cert" "$INGRESS_TLS_CERT"
    validate_readable_file "--ingress-tls-key" "$INGRESS_TLS_KEY"
    require_openssl
    validate_private_key_pem "$INGRESS_TLS_KEY"

    INGRESS_CERT_SHA256=$(certificate_chain_sha256 \
      "$INGRESS_TLS_CERT" 2>/dev/null || true)
    if [[ ! "$INGRESS_CERT_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
      err "Could not calculate the SHA-256 digest of the Ingress certificate chain"
    fi

    INGRESS_CERT_FILE_SHA256=$(file_sha256 "$INGRESS_TLS_CERT") ||
      err "Could not calculate the SHA-256 digest of the Ingress certificate file"
    INGRESS_KEY_FILE_SHA256=$(file_sha256 "$INGRESS_TLS_KEY") ||
      err "Could not calculate the SHA-256 digest of the Ingress private key file"

    if [[ -z "$INGRESS_TLS_SECRET" ]]; then
      INGRESS_TLS_SECRET="${PRJ_PREFIX}-ingress-tls-${INGRESS_CERT_SHA256:0:12}"
    fi
    validate_dns_subdomain "--ingress-tls-secret" "$INGRESS_TLS_SECRET"
  fi
}

wait_for_operator() {
  local subscription_name=$1
  local namespace=${2:-openshift-operators}
  local max_wait=${3:-600}
  local deadline=0
  local csv=""
  local phase=""
  local install_plan=""

  info "Esperando a que el operador de la subscription $subscription_name esté completamente instalado..."

  deadline=$(($(date +%s) + max_wait))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    # Obtener el nombre del CSV instalado desde la subscription usando el CRD completo
    csv=$(oc --request-timeout=15s get subscriptions.operators.coreos.com \
      "$subscription_name" -n "$namespace" \
      -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)

    if [ -n "$csv" ] && [ "$csv" != "null" ]; then
      # Verificar que el CSV existe y está en estado Succeeded
      phase=$(oc --request-timeout=15s get csv "$csv" -n "$namespace" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)

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
      install_plan=$(oc --request-timeout=15s get \
        subscriptions.operators.coreos.com "$subscription_name" \
        -n "$namespace" \
        -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)
      if [ -n "$install_plan" ] && [ "$install_plan" != "null" ]; then
        echo -n "[installing]"
      fi
    fi
    
    wait_seconds 10
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

pem_certificate_bodies() {
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
    }
    line == "-----BEGIN CERTIFICATE-----" {
      inside = 1
      body = ""
      next
    }
    line == "-----END CERTIFICATE-----" {
      if (inside) {
        print body
      }
      inside = 0
      next
    }
    inside {
      gsub(/[[:space:]]/, "", line)
      body = body line
    }
  ' "$1"
}

certificate_bundle_contains() {
  local source_file=$1
  local target_file=$2
  local source_body=""
  local source_count=0
  local target_bodies=""

  target_bodies=$(pem_certificate_bodies "$target_file")
  while IFS= read -r source_body; do
    [[ -n "$source_body" ]] || continue
    source_count=$((source_count + 1))
    if ! printf '%s\n' "$target_bodies" | grep -Fqx -- "$source_body"; then
      return 1
    fi
  done < <(pem_certificate_bodies "$source_file")

  [[ "$source_count" -gt 0 ]]
}

managed_bundle_contains_ca() {
  local source_file=$1
  local managed_bundle=""

  managed_bundle=$(mktemp) || return 1
  if ! oc --request-timeout=15s get configmap trusted-ca-bundle \
    -n openshift-config-managed \
    -o jsonpath='{.data.ca-bundle\.crt}' >"$managed_bundle" 2>/dev/null; then
    rm -f -- "$managed_bundle"
    return 1
  fi

  if certificate_bundle_contains "$source_file" "$managed_bundle"; then
    rm -f -- "$managed_bundle"
    return 0
  fi
  rm -f -- "$managed_bundle"
  return 1
}

cluster_operator_is_healthy() {
  local operator_name=$1
  local state=""

  if ! state=$(oc --request-timeout=15s get clusteroperator "$operator_name" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{"|"}{.status.conditions[?(@.type=="Progressing")].status}{"|"}{.status.conditions[?(@.type=="Degraded")].status}' \
    2>/dev/null); then
    return 1
  fi

  [[ "$state" == "True|False|False" ]]
}

machine_config_pools_are_healthy() {
  local pool_states=""
  local pool_name=""
  local generation=""
  local observed_generation=""
  local paused=""
  local machine_count=""
  local ready_count=""
  local updated_count=""
  local unavailable_count=""
  local degraded_count=""

  if ! pool_states=$(oc --request-timeout=15s get machineconfigpool \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.generation}{"|"}{.status.observedGeneration}{"|"}{.spec.paused}{"|"}{.status.machineCount}{"|"}{.status.readyMachineCount}{"|"}{.status.updatedMachineCount}{"|"}{.status.unavailableMachineCount}{"|"}{.status.degradedMachineCount}{"\n"}{end}' \
    2>/dev/null); then
    return 1
  fi

  [[ -n "$pool_states" ]] || return 1

  while IFS='|' read -r pool_name generation observed_generation paused \
    machine_count ready_count updated_count unavailable_count degraded_count; do
    [[ -n "$pool_name" ]] || continue
    [[ "$paused" != "true" && "$paused" != "True" ]] || return 1
    [[ "$generation" == "$observed_generation" ]] || return 1
    [[ "$machine_count" =~ ^[0-9]+$ ]] || return 1
    [[ "$ready_count" == "$machine_count" ]] || return 1
    [[ "$updated_count" == "$machine_count" ]] || return 1
    [[ "$unavailable_count" == "0" ]] || return 1
    [[ "$degraded_count" == "0" ]] || return 1
  done <<<"$pool_states"

  return 0
}

wait_for_cluster_trusted_ca() {
  local ca_source_file=$1
  local max_wait=${2:-1200}
  local initial_delay=${3:-60}
  local deadline=0
  local healthy_samples=0
  local configured_ca=""

  deadline=$(($(date +%s) + max_wait))
  info "Esperando la propagación del bundle de CA del cluster..."
  if [ "$initial_delay" -gt 0 ]; then
    wait_seconds "$initial_delay"
  fi

  while [ "$(date +%s)" -lt "$deadline" ]; do
    configured_ca=$(oc --request-timeout=15s get proxy/cluster \
      -o jsonpath='{.spec.trustedCA.name}' 2>/dev/null || true)

    if [[ "$configured_ca" == "$CA_CONFIGMAP" ]] &&
      managed_bundle_contains_ca "$ca_source_file" &&
      cluster_operator_is_healthy network &&
      cluster_operator_is_healthy machine-config &&
      machine_config_pools_are_healthy; then
      healthy_samples=$((healthy_samples + 1))
      if [ "$healthy_samples" -ge 2 ]; then
        info "El bundle $CA_CONFIGMAP fue propagado y los operadores están estables"
        return 0
      fi
    else
      healthy_samples=0
    fi

    wait_seconds 10
  done

  err "Timeout esperando la propagación de $CA_CONFIGMAP después de ${max_wait}s"
}

validate_ingress_tls_with_openssl() (
  local certificate_chain=$1
  local private_key=$2
  local ingress_domain=$3
  local ca_file=$4
  local trust_mode=$5
  local temp_dir=""
  local certificate_dir=""
  local certificate_count=""
  local certificate_file=""
  local leaf_certificate=""
  local root_certificate=""
  local current_certificate=""
  local next_certificate=""
  local current_issuer=""
  local next_subject=""
  local root_issuer=""
  local root_subject=""
  local expected_san=""
  local untrusted_file=""
  local untrusted_last=0
  local index=1

  require_openssl
  temp_dir=$(mktemp -d) || err "Could not create a TLS validation directory"
  trap '[[ -z ${temp_dir:-} ]] || rm -rf -- "$temp_dir"' EXIT
  trap 'exit 1' HUP INT TERM

  certificate_dir="$temp_dir/certificates"
  mkdir "$certificate_dir"

  if ! certificate_count=$(split_pem_certificates \
    "$certificate_chain" "$certificate_dir"); then
    err "--ingress-tls-cert must contain only a complete PEM certificate chain"
  fi
  if [ "$certificate_count" -lt 2 ]; then
    err "--ingress-tls-cert must contain the leaf certificate followed by its root CA"
  fi

  while [ "$index" -le "$certificate_count" ]; do
    certificate_file=$(printf '%s/cert-%04d.pem' \
      "$certificate_dir" "$index")

    if ! openssl x509 -in "$certificate_file" -noout \
      >/dev/null 2>&1; then
      err "Certificate $index in the Ingress chain is not valid X.509"
    fi

    if ! openssl x509 -in "$certificate_file" -noout -checkend 0 \
      >/dev/null 2>&1; then
      err "Certificate $index in the Ingress chain is expired"
    fi

    if [ "$index" -eq 1 ]; then
      if openssl x509 -in "$certificate_file" -noout -text 2>/dev/null |
        grep -Eq 'CA:[[:space:]]*TRUE'; then
        err "The Ingress leaf certificate must not be a CA certificate"
      fi
    elif ! openssl x509 -in "$certificate_file" -noout -text 2>/dev/null |
      grep -Eq 'CA:[[:space:]]*TRUE'; then
      err "Certificate $index in the Ingress chain is not a CA certificate"
    fi

    index=$((index + 1))
  done

  leaf_certificate="$certificate_dir/cert-0001.pem"
  root_certificate=$(printf '%s/cert-%04d.pem' \
    "$certificate_dir" "$certificate_count")

  index=1
  while [ "$index" -lt "$certificate_count" ]; do
    current_certificate=$(printf '%s/cert-%04d.pem' \
      "$certificate_dir" "$index")
    next_certificate=$(printf '%s/cert-%04d.pem' \
      "$certificate_dir" "$((index + 1))")
    current_issuer=$(openssl x509 -in "$current_certificate" \
      -noout -issuer -nameopt RFC2253 2>/dev/null)
    next_subject=$(openssl x509 -in "$next_certificate" \
      -noout -subject -nameopt RFC2253 2>/dev/null)
    current_issuer=${current_issuer#issuer=}
    next_subject=${next_subject#subject=}
    current_issuer=${current_issuer# }
    next_subject=${next_subject# }

    if [[ "$current_issuer" != "$next_subject" ]]; then
      err "The Ingress certificate chain must be ordered leaf, intermediates, root"
    fi
    if ! openssl verify -partial_chain -trusted "$next_certificate" \
      "$current_certificate" >/dev/null 2>&1; then
      err "Certificate $index is not signed by certificate $((index + 1)) in the Ingress chain"
    fi
    index=$((index + 1))
  done

  root_subject=$(openssl x509 -in "$root_certificate" \
    -noout -subject -nameopt RFC2253 2>/dev/null)
  root_issuer=$(openssl x509 -in "$root_certificate" \
    -noout -issuer -nameopt RFC2253 2>/dev/null)
  root_subject=${root_subject#subject=}
  root_issuer=${root_issuer#issuer=}
  root_subject=${root_subject# }
  root_issuer=${root_issuer# }
  if [[ "$root_subject" != "$root_issuer" ]] ||
    ! openssl verify -CAfile "$root_certificate" \
      "$root_certificate" >/dev/null 2>&1; then
    err "The last certificate in the Ingress chain must be a self-signed root CA"
  fi

  if ! openssl x509 -in "$leaf_certificate" -pubkey -noout 2>/dev/null |
    openssl pkey -pubin -outform DER \
      >"$temp_dir/certificate-public.der" 2>/dev/null; then
    err "Could not extract the public key from the Ingress certificate"
  fi

  if ! openssl pkey -in "$private_key" -passin pass: \
    -pubout -outform DER >"$temp_dir/private-key-public.der" 2>/dev/null; then
    err "Could not derive the public key from the Ingress private key"
  fi

  if ! cmp -s "$temp_dir/certificate-public.der" \
    "$temp_dir/private-key-public.der"; then
    err "The Ingress certificate and private key do not match"
  fi

  expected_san=$(printf 'DNS:*.%s' "$ingress_domain" |
    tr '[:upper:]' '[:lower:]')
  if ! certificate_dns_sans "$leaf_certificate" |
    tr '[:upper:]' '[:lower:]' |
    grep -Fqx -- "$expected_san"; then
    err "The leaf certificate must contain the exact wildcard SAN *.$ingress_domain"
  fi

  untrusted_file="$temp_dir/untrusted.pem"
  : >"$untrusted_file"

  case "$trust_mode" in
  file | none)
    [[ -n "$ca_file" ]] ||
      err "A trusted CA bundle is required to validate the Ingress certificate"
    root_certificate=$ca_file
    untrusted_last=$certificate_count
    ;;
  *)
    err "A custom Ingress certificate requires --ca-mode file or --ca-mode none"
    ;;
  esac

  index=2
  while [ "$index" -le "$untrusted_last" ]; do
    certificate_file=$(printf '%s/cert-%04d.pem' \
      "$certificate_dir" "$index")
    command cat "$certificate_file" >>"$untrusted_file"
    index=$((index + 1))
  done

  if [[ -s "$untrusted_file" ]]; then
    if ! openssl verify -purpose sslserver -CAfile "$root_certificate" \
      -untrusted "$untrusted_file" "$leaf_certificate" >/dev/null 2>&1; then
      err "The Ingress certificate chain is not trusted by the selected CA"
    fi
  elif ! openssl verify -purpose sslserver -CAfile "$root_certificate" \
    "$leaf_certificate" >/dev/null 2>&1; then
    err "The Ingress certificate is not trusted by the selected CA"
  fi
)

preflight_ingress_tls() (
  local cluster_trust_file=""
  local controller_state=""
  local ingress_domain=""
  local verification_ca_file="$CA_FILE"

  [[ -n "$INGRESS_TLS_CERT" ]] || return 0

  trap '[[ -z ${cluster_trust_file:-} ]] || rm -f -- "$cluster_trust_file"' EXIT
  trap 'exit 1' HUP INT TERM

  if ! controller_state=$(oc --request-timeout=15s \
    get ingresscontroller.operator "$INGRESS_CONTROLLER" \
    -n openshift-ingress-operator \
    -o jsonpath='{.status.domain}{"|"}{.spec.defaultCertificate.name}' \
    2>/dev/null); then
    err "IngressController/$INGRESS_CONTROLLER does not exist in openshift-ingress-operator"
  fi

  ingress_domain=${controller_state%%|*}
  [[ -n "$ingress_domain" ]] ||
    err "IngressController/$INGRESS_CONTROLLER has no observed domain"
  validate_dns_subdomain "IngressController/$INGRESS_CONTROLLER domain" \
    "$ingress_domain"

  if [[ "$CA_MODE" == "none" ]]; then
    cluster_trust_file=$(mktemp) ||
      err "Could not create a cluster trust validation file"
    if ! oc --request-timeout=15s get configmap trusted-ca-bundle \
      -n openshift-config-managed \
      -o jsonpath='{.data.ca-bundle\.crt}' >"$cluster_trust_file" \
      2>/dev/null; then
      err "Could not read the cluster managed trust bundle"
    fi
    [[ -s "$cluster_trust_file" ]] ||
      err "The cluster managed trust bundle is empty"
    verification_ca_file=$cluster_trust_file
  fi

  validate_ingress_tls_with_openssl \
    "$INGRESS_TLS_CERT" \
    "$INGRESS_TLS_KEY" \
    "$ingress_domain" \
    "$verification_ca_file" \
    "$CA_MODE"

  if ! oc create secret tls "$INGRESS_TLS_SECRET" \
    --cert="$INGRESS_TLS_CERT" \
    --key="$INGRESS_TLS_KEY" \
    -n openshift-ingress \
    --dry-run=client -o name >/dev/null 2>&1; then
    err "The Ingress certificate/key pair is invalid, encrypted, or does not match"
  fi

  validate_existing_ingress_tls_secret "during preflight" || true

  if ! cluster_operator_is_healthy ingress ||
    ! cluster_operator_is_healthy authentication ||
    ! cluster_operator_is_healthy console; then
    err "Ingress, authentication, and console operators must be stable before replacing the default Ingress certificate"
  fi
)

configure_cluster_trusted_ca() (
  if [[ "$CA_MODE" == "none" ]]; then
    info "Preservando proxy/cluster.spec.trustedCA sin cambios"
    return 0
  fi

  local ca_source_file=""
  local tmp_ca_file=""
  local existing_ca_file=""
  local existing_trusted_ca=""
  local existing_configmap=""
  local ca_base64=""
  local ca_patch=""

  trap '[[ -z ${tmp_ca_file:-} ]] || rm -f -- "$tmp_ca_file"; [[ -z ${existing_ca_file:-} ]] || rm -f -- "$existing_ca_file"' EXIT
  trap 'exit 1' HUP INT TERM

  if ! existing_trusted_ca=$(oc --request-timeout=15s get proxy/cluster \
    -o jsonpath='{.spec.trustedCA.name}' 2>/dev/null); then
    err "No se pudo consultar proxy/cluster.spec.trustedCA"
  fi
  if [[ -n "$existing_trusted_ca" && "$existing_trusted_ca" != "$CA_CONFIGMAP" ]]; then
    err "proxy/cluster already references '$existing_trusted_ca'. Use --ca-mode none to preserve it or --ca-configmap $existing_trusted_ca with the complete bundle"
  fi

  if ! existing_configmap=$(oc --request-timeout=15s get configmap \
    "$CA_CONFIGMAP" -n openshift-config --ignore-not-found -o name \
    2>/dev/null); then
    err "Could not check ConfigMap/$CA_CONFIGMAP in openshift-config"
  fi
  if [[ -n "$existing_configmap" && "$existing_trusted_ca" != "$CA_CONFIGMAP" &&
    "$CA_CONFIGMAP_EXPLICIT" != "true" ]]; then
    err "ConfigMap/$CA_CONFIGMAP already exists and is not selected by proxy/cluster; choose a different --project-prefix or pass --ca-configmap explicitly"
  fi

  if [[ "$CA_MODE" == "file" ]]; then
    info "Usando el bundle de CA proporcionado por el usuario"
    ca_source_file=$CA_FILE
  else
    info "Extrayendo la CA interna desde openshift-ingress-operator/router-ca"
    ca_base64=$(oc --request-timeout=15s get secret router-ca \
      -n openshift-ingress-operator \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)
    [[ -n "$ca_base64" ]] || err "No se pudo obtener openshift-ingress-operator/router-ca"

    tmp_ca_file=$(mktemp)
    if ! decode_base64_to_file "$ca_base64" "$tmp_ca_file"; then
      err "Error al decodificar la CA interna del router"
    fi
    ca_source_file=$tmp_ca_file
  fi

  if [[ "$CA_MODE" == "router" && "$CA_MODE_EXPLICIT" != "true" &&
    "$existing_trusted_ca" == "$CA_CONFIGMAP" && -n "$existing_configmap" ]]; then
    existing_ca_file=$(mktemp)
    if ! oc --request-timeout=15s get configmap "$CA_CONFIGMAP" \
      -n openshift-config \
      -o jsonpath='{.data.ca-bundle\.crt}' >"$existing_ca_file" \
      2>/dev/null; then
      err "Could not read ConfigMap/$CA_CONFIGMAP in openshift-config"
    fi
    if ! certificate_bundle_contains "$ca_source_file" "$existing_ca_file"; then
      err "The existing $CA_CONFIGMAP does not contain the current router CA; use --ca-mode none to preserve it or pass --ca-mode router explicitly to refresh it"
    fi
    wait_for_cluster_trusted_ca "$existing_ca_file" 1200 0
    info "El bundle existente $CA_CONFIGMAP contiene la CA actual del router"
    return 0
  fi

  if ! cluster_operator_is_healthy network ||
    ! cluster_operator_is_healthy machine-config ||
    ! machine_config_pools_are_healthy; then
    err "Network, machine-config, and MachineConfigPools must be stable before changing proxy/cluster.spec.trustedCA"
  fi

  info "Creando o actualizando ConfigMap $CA_CONFIGMAP en openshift-config"
  if ! oc create configmap "$CA_CONFIGMAP" \
    --from-file=ca-bundle.crt="$ca_source_file" \
    -n openshift-config --dry-run=client -o yaml |
    oc apply -f - >/dev/null; then
    err "No se pudo crear o actualizar el bundle de CA del cluster"
  fi

  ca_patch=$(printf '{"spec":{"trustedCA":{"name":"%s"}}}' "$CA_CONFIGMAP")
  if ! oc patch proxy/cluster --type=merge -p "$ca_patch" >/dev/null; then
    err "No se pudo actualizar proxy/cluster.spec.trustedCA"
  fi

  wait_for_cluster_trusted_ca "$ca_source_file" 1200
)

wait_for_ingress_controller() {
  local max_wait=${1:-600}
  local deadline=0
  local healthy_samples=0
  local controller_state=""
  local generation=""
  local observed_generation=""
  local configured_secret=""
  local available_replicas="0"
  local available=""
  local progressing=""
  local degraded=""

  deadline=$(($(date +%s) + max_wait))
  info "Esperando a que IngressController/$INGRESS_CONTROLLER esté disponible..."
  wait_seconds 20

  while [ "$(date +%s)" -lt "$deadline" ]; do
    controller_state=$(oc --request-timeout=15s \
      get ingresscontroller.operator "$INGRESS_CONTROLLER" \
      -n openshift-ingress-operator \
      -o jsonpath='{.metadata.generation}{"|"}{.status.observedGeneration}{"|"}{.spec.defaultCertificate.name}{"|"}{.status.conditions[?(@.type=="Available")].status}{"|"}{.status.conditions[?(@.type=="Progressing")].status}{"|"}{.status.conditions[?(@.type=="Degraded")].status}{"|"}{.status.availableReplicas}' \
      2>/dev/null || true)
    IFS='|' read -r generation observed_generation configured_secret available \
      progressing degraded available_replicas <<<"$controller_state"

    if [[ -n "$generation" && "$generation" == "$observed_generation" &&
      "$configured_secret" == "$INGRESS_TLS_SECRET" &&
      "$available" == "True" && "$progressing" == "False" &&
      "$degraded" == "False" &&
      "$available_replicas" =~ ^[0-9]+$ && "$available_replicas" -gt 0 ]] &&
      cluster_operator_is_healthy ingress &&
      cluster_operator_is_healthy authentication &&
      cluster_operator_is_healthy console; then
      healthy_samples=$((healthy_samples + 1))
      if [ "$healthy_samples" -ge 2 ]; then
        info "IngressController/$INGRESS_CONTROLLER usa el Secret $INGRESS_TLS_SECRET y está estable"
        return 0
      fi
    else
      healthy_samples=0
    fi

    wait_seconds 10
  done

  err "Timeout esperando la reconciliación de IngressController/$INGRESS_CONTROLLER"
}

configure_ingress_tls() {
  local ingress_patch=""

  [[ -n "$INGRESS_TLS_CERT" ]] || return 0

  if ! cluster_operator_is_healthy ingress ||
    ! cluster_operator_is_healthy authentication ||
    ! cluster_operator_is_healthy console; then
    err "Ingress, authentication, and console operators are not stable immediately before replacing the default Ingress certificate"
  fi

  if validate_existing_ingress_tls_secret \
    "immediately before Ingress configuration"; then
    info "Reutilizando el Secret TLS versionado $INGRESS_TLS_SECRET"
  else
    info "Creando el Secret TLS versionado $INGRESS_TLS_SECRET en openshift-ingress"
    if ! oc create secret tls "$INGRESS_TLS_SECRET" \
      --cert="$INGRESS_TLS_CERT" \
      --key="$INGRESS_TLS_KEY" \
      -n openshift-ingress >/dev/null; then
      err "No se pudo crear el Secret TLS del Ingress Controller"
    fi

    if ! oc annotate secret "$INGRESS_TLS_SECRET" \
      -n openshift-ingress \
      "$INGRESS_CERT_ANNOTATION=$INGRESS_CERT_SHA256" \
      --overwrite >/dev/null; then
      if oc --request-timeout=15s delete secret "$INGRESS_TLS_SECRET" \
        -n openshift-ingress --ignore-not-found >/dev/null 2>&1; then
        err "No se pudo registrar el digest de la cadena; el Secret recién creado fue eliminado"
      fi
      err "No se pudo registrar el digest de la cadena ni eliminar Secret/$INGRESS_TLS_SECRET"
    fi
  fi

  ingress_patch=$(printf '{"spec":{"defaultCertificate":{"name":"%s"}}}' "$INGRESS_TLS_SECRET")
  if ! oc patch ingresscontroller.operator "$INGRESS_CONTROLLER" \
    -n openshift-ingress-operator --type=merge -p "$ingress_patch" >/dev/null; then
    err "No se pudo configurar el certificado de IngressController/$INGRESS_CONTROLLER"
  fi

  wait_for_ingress_controller 600
}

wait_for_pipelines_as_code_route() {
  local namespace=${1:-openshift-pipelines}
  local route_name="pipelines-as-code-controller"
  local max_wait=${2:-600}
  local deadline=0
  local route=""

  info "Esperando a que la ruta $route_name esté disponible en el namespace $namespace..."

  deadline=$(($(date +%s) + max_wait))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    # Intentar obtener la ruta primero en openshift-pipelines
    route=$(oc --request-timeout=15s get route "$route_name" \
      -n "$namespace" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    
    if [ -n "$route" ] && [ "$route" != "null" ]; then
      info "Ruta $route_name disponible en $namespace (host: $route)"
      return 0
    fi
    
    # Si no está en openshift-pipelines, intentar en pipelines-as-code
    if [ "$namespace" == "openshift-pipelines" ]; then
      route=$(oc --request-timeout=15s get route "$route_name" \
        -n pipelines-as-code -o jsonpath='{.spec.host}' \
        2>/dev/null || true)
      if [ -n "$route" ] && [ "$route" != "null" ]; then
        info "Ruta $route_name disponible en pipelines-as-code (host: $route)"
        return 0
      fi
    fi
    
    wait_seconds 10
  done
  
  err "Timeout esperando a que la ruta $route_name esté disponible (esperado: $max_wait segundos)"
}

wait_for_argocd_route() {
  local namespace=$1
  local max_wait=${2:-600}
  local deadline=0

  deadline=$(($(date +%s) + max_wait))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if oc --request-timeout=15s get route argocd-server \
      -n "$namespace" >/dev/null 2>&1; then
      info "La ruta argocd-server está disponible en $namespace"
      return 0
    fi
    wait_seconds 10
  done

  err "Timeout esperando la ruta argocd-server después de ${max_wait}s"
}

wait_for_taskrun_completion() {
  local taskrun_name=$1
  local namespace=$2
  local max_wait=${3:-600}
  local deadline=0
  local taskrun_status=""

  deadline=$(($(date +%s) + max_wait))

  while [ "$(date +%s)" -lt "$deadline" ]; do
    taskrun_status=$(oc --request-timeout=15s get taskrun "$taskrun_name" \
      -n "$namespace" \
      -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' \
      2>/dev/null || true)

    case "$taskrun_status" in
    True)
      info "TaskRun $taskrun_name completado correctamente"
      return 0
      ;;
    False)
      err "TaskRun $taskrun_name falló; revise su estado sin imprimir valores de Secrets"
      ;;
    esac

    echo "waiting for Gitea init TaskRun to complete..."
    wait_seconds 10
  done

  err "Timeout esperando TaskRun/$taskrun_name después de ${max_wait}s"
}

wait_for_gitea_repository() {
  local repository_url=$1
  local max_wait=${2:-600}
  local deadline=0
  local repository_available="false"

  deadline=$(($(date +%s) + max_wait))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    repository_available="false"
    case "$CA_MODE" in
    router)
      if curl_for_gitea --connect-timeout 5 --max-time 15 --fail --silent \
        --show-error --location --insecure \
        "$repository_url/info/refs?service=git-upload-pack" \
        >/dev/null 2>&1; then
        repository_available="true"
      fi
      ;;
    file)
      if curl_for_gitea --connect-timeout 5 --max-time 15 --fail --silent \
        --show-error --location --cacert "$CA_FILE" \
        "$repository_url/info/refs?service=git-upload-pack" \
        >/dev/null 2>&1; then
        repository_available="true"
      fi
      ;;
    none)
      if curl_for_gitea --connect-timeout 5 --max-time 15 --fail --silent \
        --show-error --location \
        "$repository_url/info/refs?service=git-upload-pack" \
        >/dev/null 2>&1; then
        repository_available="true"
      fi
      ;;
    esac

    if [[ "$repository_available" == "true" ]]; then
      info "El repositorio de Gitea está disponible"
      return 0
    fi
    wait_seconds 10
  done

  err "Timeout esperando el repositorio de Gitea después de ${max_wait}s"
}

resolve_curl_options() {
  local version_output=""

  version_output=$(curl --version 2>/dev/null) ||
    err "Could not determine the curl version"
  CURL_SSL_NO_REVOKE="false"

  case "$version_output" in
  *[Ss][Cc][Hh][Aa][Nn][Nn][Ee][Ll]*)
    curl --ssl-no-revoke --version >/dev/null 2>&1 ||
      err "curl with Schannel must support --ssl-no-revoke; update curl"
    CURL_SSL_NO_REVOKE="true"
    ;;
  esac
}

curl_for_gitea() {
  if [[ "$CURL_SSL_NO_REVOKE" == "true" ]]; then
    curl --ssl-no-revoke "$@"
  else
    curl "$@"
  fi
}

configure_git_tls_environment() {
  export GIT_TERMINAL_PROMPT=0

  case "$CA_MODE" in
  router)
    unset GIT_SSL_CAINFO
    export GIT_SSL_NO_VERIFY=true
    ;;
  file)
    unset GIT_SSL_NO_VERIFY
    export GIT_SSL_CAINFO="$CA_FILE"
    ;;
  none) ;;
  esac
}

git_network() {
  case "$CA_MODE" in
  router)
    git -c http.sslVerify=false "$@"
    ;;
  file)
    git -c http.sslVerify=true \
      -c http.sslCAInfo="$CA_FILE" \
      -c http.schannelUseSSLCAInfo=true "$@"
    ;;
  none)
    git "$@"
    ;;
  esac
}

command.install() {
  local tmp_dir=""

  oc version >/dev/null 2>&1 || err "no oc binary found"
  command -v git >/dev/null 2>&1 || err "git is required"
  command -v curl >/dev/null 2>&1 || err "curl is required"
  resolve_curl_options

  preflight_ingress_tls

  info "Configurando la confianza TLS del cluster..."
  configure_cluster_trusted_ca

  info "Configurando el certificado TLS del Ingress Controller..."
  configure_ingress_tls

  configure_git_tls_environment

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
  sed "s/@HOSTNAME/$GITEA_HOSTNAME/g" config/gitea-configmap.yaml |
    oc apply -f - -n "$cicd_prj" ||
    err "Could not apply Gitea configuration"
  oc rollout restart deployment/gitea -n "$cicd_prj" ||
    err "Could not restart Gitea with the updated configuration"
  oc rollout status deployment/gitea -n "$cicd_prj" --timeout=5m ||
    err "Gitea deployment did not become available within 5 minutes"
  
  # Crear taskrun siempre con oc create (tiene generateName, no se puede usar apply)
  info "Creando TaskRun para inicializar Gitea..."
  if ! taskrun_name=$(sed "s#@webhook-url@#https://$WEBHOOK_URL#g" \
    config/gitea-init-taskrun.yaml |
    sed "s#@gitea-url@#https://$GITEA_HOSTNAME#g" |
    oc create -f - -n "$cicd_prj" \
      -o jsonpath='{.metadata.name}' 2>/dev/null); then
    err "No se pudo crear el TaskRun de inicialización de Gitea"
  fi
  [[ -n "$taskrun_name" ]] ||
    err "No se pudo obtener el nombre del TaskRun creado"

  info "Esperando a que el TaskRun $taskrun_name termine su ejecución..."
  wait_for_taskrun_completion "$taskrun_name" "$cicd_prj" 600

  echo "Waiting for source code to be imported to Gitea..."
  wait_for_gitea_repository \
    "https://$GITEA_HOSTNAME/gitea/spring-petclinic" 600

  wait_seconds 10

  sleep 10

  info "Updating pipelinerun values for the demo environment"
  tmp_dir=$(mktemp -d) || err "Could not create a temporary Git directory"
  trap '[[ -z ${tmp_dir:-} ]] || rm -rf -- "$tmp_dir"' EXIT
  pushd "$tmp_dir"
  # Clonar solo si el directorio no existe o está vacío
  if [ ! -d spring-petclinic ] || [ -z "$(ls -A spring-petclinic 2>/dev/null)" ]; then
    git_network clone https://"$GITEA_HOSTNAME"/gitea/spring-petclinic
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
    git commit -m "Updated manifests git url"
    git remote remove auth-origin 2>/dev/null || true
    git remote add auth-origin https://gitea:openshift@"$GITEA_HOSTNAME"/gitea/spring-petclinic
    if ! git_network push auth-origin cicd-demo >/dev/null 2>&1; then
      err "No se pudo publicar la configuración actualizada en Gitea"
    fi
  else
    info "El repositorio ya está actualizado con la URL correcta"
  fi
  popd
  rm -rf -- "$tmp_dir"
  tmp_dir=""
  trap - EXIT

  info "Configuring pipelines-as-code"
  # Verificar si el Repository ya existe
  if oc get repository spring-petclinic -n "$cicd_prj" >/dev/null 2>&1; then
    info "El Repository pipelines-as-code ya está configurado"
  else
    cat <<EOF | oc apply -f - -n "$cicd_prj"
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
EOF
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
  wait_for_argocd_route "$cicd_prj" 600

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

command.start() (
  local tmp_dir=""

  oc version >/dev/null 2>&1 || err "no oc binary found"
  command -v git >/dev/null 2>&1 || err "git is required"
  configure_git_tls_environment
  if ! GITEA_HOSTNAME=$(oc --request-timeout=15s get route gitea \
    -o template --template='{{.spec.host}}' -n "$cicd_prj" 2>/dev/null); then
    err "No se pudo obtener la ruta de Gitea en $cicd_prj"
  fi
  [[ -n "$GITEA_HOSTNAME" ]] || err "La ruta de Gitea no tiene host"
  info "Pushing a change to https://$GITEA_HOSTNAME/gitea/spring-petclinic-config"
  tmp_dir=$(mktemp -d) || err "Could not create a temporary Git directory"
  trap '[[ -z ${tmp_dir:-} ]] || rm -rf -- "$tmp_dir"' EXIT
  trap 'exit 1' HUP INT TERM
  pushd "$tmp_dir"
  if ! git_network clone https://"$GITEA_HOSTNAME"/gitea/spring-petclinic; then
    err "No se pudo clonar spring-petclinic desde Gitea"
  fi
  cd spring-petclinic
  git config user.email "openshift-pipelines@redhat.com"
  git config user.name "openshift-pipelines"
  echo "   " >>readme.md
  git add readme.md
  git commit -m "Updated readme.md"
  git remote add auth-origin https://gitea:openshift@"$GITEA_HOSTNAME"/gitea/spring-petclinic
  if ! git_network push auth-origin cicd-demo >/dev/null 2>&1; then
    err "No se pudo publicar el cambio de demostración en Gitea"
  fi
  popd
)

command.uninstall() {
  oc delete project "$dev_prj" "$stage_prj" "$cicd_prj"
}

main() {
  local fn="command.$COMMAND"
  valid_command "$fn" || {
    err "invalid command '$COMMAND'"
  }

  validate_tls_options
  cd "$SCRIPT_DIR"
  $fn
  return $?
}

main
