#Requires -Version 5.1

$ErrorActionPreference = "Stop"
Set-PSDebug -Off
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$PRJ_PREFIX = "demo"
$COMMAND = "help"
$COMMAND_SET = $false
$CA_MODE = "router"
$CA_MODE_EXPLICIT = $false
$CA_FILE = ""
$CA_CONFIGMAP = ""
$CA_CONFIGMAP_EXPLICIT = $false
$INGRESS_TLS_CERT = ""
$INGRESS_TLS_KEY = ""
$INGRESS_TLS_SECRET = ""
$INGRESS_TLS_SECRET_EXPLICIT = $false
$INGRESS_CERT_SHA256 = ""
$INGRESS_CERT_FILE_SHA256 = ""
$INGRESS_KEY_FILE_SHA256 = ""
$INGRESS_CONTROLLER = "default"
$INGRESS_CERT_ANNOTATION = "openshift-cicd-demo-certificate-chain-sha256"
$TLS_OPTIONS_EXPLICIT = $false
$OPENSSL_COMMAND = ""
$CURL_COMMAND = ""

$dev_prj = "$PRJ_PREFIX-dev"
$stage_prj = "$PRJ_PREFIX-stage"
$cicd_prj = "$PRJ_PREFIX-cicd"

function Write-Info {
    param([string]$Message)
    Write-Host ""
    Write-Host "# INFO: $Message" -ForegroundColor Cyan
}

function Write-Err {
    param([string]$Message)
    Write-Host ""
    Write-Host "# ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Wait-Seconds {
    param([int]$Count = 5)
    for ($i = 1; $i -le $Count; $i++) {
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 1
    }
    Write-Host ""
}

function Test-ValidCommand {
    param([string]$CommandName)
    $functionName = "Command-$CommandName"
    return (Get-Command -Name $functionName -ErrorAction SilentlyContinue) -ne $null
}

function Command-Help {
    Write-Host @"

  Usage:
      .\demo.ps1 [command] [options]

  Example:
      .\demo.ps1 install -ProjectPrefix mydemo
      .\demo.ps1 install -CaMode file -CaFile C:\secure\pki\root-ca.pem ``
        -IngressTlsCert C:\secure\pki\wildcard-chain.pem ``
        -IngressTlsKey C:\secure\pki\wildcard.key

  COMMANDS:
      install                        Sets up the demo and creates namespaces
      uninstall                      Deletes the demo
      start                          Starts the deploy DEV pipeline
      help                           Help about this command

  OPTIONS:
      -ProjectPrefix [string]        Prefix to be added to demo project names e.g. PREFIX-dev
      -CaMode [router|file|none]     Trusted CA/Git mode (default: router)
      -CaFile [path]                 Complete CA bundle; required with -CaMode file
      -CaConfigMap [name]            Override the CA ConfigMap (install only)
      -IngressTlsCert [path]         PEM wildcard chain (install only)
      -IngressTlsKey [path]          Matching unencrypted key (install only)
      -IngressTlsSecret [name]       Override versioned Secret (install only)
"@
}

function Test-DnsSubdomain {
    param(
        [string]$Label,
        [string]$Value
    )

    $dnsSubdomainPattern = '^([a-z0-9]([-a-z0-9]*[a-z0-9])?)(\.([a-z0-9]([-a-z0-9]*[a-z0-9])?))*$'
    if ($Value.Length -gt 253 -or $Value -cnotmatch $dnsSubdomainPattern) {
        Write-Err "$Label must be a valid DNS-1123 subdomain: $Value"
    }

    foreach ($component in $Value.Split('.')) {
        if ($component.Length -gt 63) {
            Write-Err "$Label contains a DNS label longer than 63 characters: $Value"
        }
    }
}

function Test-DnsLabel {
    param(
        [string]$Label,
        [string]$Value
    )

    $dnsLabelPattern = '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
    if ($Value.Length -gt 63 -or $Value -cnotmatch $dnsLabelPattern) {
        Write-Err "$Label must be a valid DNS-1123 label with at most 63 characters: $Value"
    }
}

function Resolve-InputFile {
    param(
        [string]$Label,
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Err "$Label must reference an existing file: $Path"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $fileInfo = Get-Item -LiteralPath $resolvedPath
    if ($fileInfo.Length -eq 0) {
        Write-Err "$Label must reference a non-empty file: $resolvedPath"
    }

    return $resolvedPath
}

function Resolve-OpenSslCommand {
    $command = Get-Command -Name @("openssl.exe", "openssl") `
        -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $command) {
        Write-Err "OpenSSL 1.1.1 or newer is required to validate custom CA/TLS files"
    }

    $script:OPENSSL_COMMAND = $command.Source
    $versionOutput = (& $OPENSSL_COMMAND version 2>$null) -join ""
    $versionMatch = [regex]::Match(
        $versionOutput,
        '^OpenSSL\s+(\d+)\.(\d+)\.(\d+)'
    )
    if ($LASTEXITCODE -ne 0 -or -not $versionMatch.Success) {
        Write-Err "OpenSSL 1.1.1 or newer is required to validate custom CA/TLS files"
    }

    $major = [int]$versionMatch.Groups[1].Value
    $minor = [int]$versionMatch.Groups[2].Value
    $patch = [int]$versionMatch.Groups[3].Value
    if ($major -lt 1 -or
        ($major -eq 1 -and $minor -lt 1) -or
        ($major -eq 1 -and $minor -eq 1 -and $patch -lt 1)) {
        Write-Err "OpenSSL 1.1.1 or newer is required to validate custom CA/TLS files"
    }
}

function Resolve-CurlCommand {
    $command = Get-Command -Name @("curl.exe", "curl") `
        -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $command) {
        Write-Err "curl.exe or curl is required to check Gitea readiness"
    }

    $script:CURL_COMMAND = $command.Source
}

function Assert-GitCommand {
    $command = Get-Command -Name "git" -CommandType Application `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        Write-Err "git is required"
    }
}

function Get-GitTlsArguments {
    switch ($CA_MODE) {
        "router" {
            Write-Output @("-c", "http.sslVerify=false")
        }
        "file" {
            Write-Output @(
                "-c", "http.sslVerify=true",
                "-c", "http.sslCAInfo=$CA_FILE",
                "-c", "http.schannelUseSSLCAInfo=true"
            )
        }
        "none" { }
    }
}

function Invoke-GitNetwork {
    param(
        [string[]]$Arguments,
        [switch]$Quiet
    )

    $hadPrompt = Test-Path Env:GIT_TERMINAL_PROMPT
    $hadNoVerify = Test-Path Env:GIT_SSL_NO_VERIFY
    $hadCaInfo = Test-Path Env:GIT_SSL_CAINFO
    $previousPrompt = if ($hadPrompt) { $env:GIT_TERMINAL_PROMPT } else { $null }
    $previousNoVerify = if ($hadNoVerify) { $env:GIT_SSL_NO_VERIFY } else { $null }
    $previousCaInfo = if ($hadCaInfo) { $env:GIT_SSL_CAINFO } else { $null }
    $exitCode = 1

    try {
        $env:GIT_TERMINAL_PROMPT = "0"
        switch ($CA_MODE) {
            "router" {
                Remove-Item Env:GIT_SSL_CAINFO -ErrorAction SilentlyContinue
                $env:GIT_SSL_NO_VERIFY = "true"
            }
            "file" {
                Remove-Item Env:GIT_SSL_NO_VERIFY -ErrorAction SilentlyContinue
                $env:GIT_SSL_CAINFO = $CA_FILE
            }
            "none" { }
        }

        $gitTlsArguments = @(Get-GitTlsArguments)
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            if ($Quiet) {
                $null = & git @gitTlsArguments @Arguments 2>$null
            } else {
                & git @gitTlsArguments @Arguments | Out-Host
            }
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    } finally {
        if ($hadPrompt) {
            $env:GIT_TERMINAL_PROMPT = $previousPrompt
        } else {
            Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
        }
        if ($hadNoVerify) {
            $env:GIT_SSL_NO_VERIFY = $previousNoVerify
        } else {
            Remove-Item Env:GIT_SSL_NO_VERIFY -ErrorAction SilentlyContinue
        }
        if ($hadCaInfo) {
            $env:GIT_SSL_CAINFO = $previousCaInfo
        } else {
            Remove-Item Env:GIT_SSL_CAINFO -ErrorAction SilentlyContinue
        }
    }

    return $exitCode
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Invoke-OcMergePatch {
    param(
        [string]$Resource,
        [string]$Name,
        [hashtable]$Patch,
        [string]$Namespace = "",
        [string]$FailureMessage
    )

    $patchFile = New-TemporaryFile
    $patchExitCode = 1
    try {
        $patchJson = $Patch | ConvertTo-Json -Depth 8 -Compress
        Write-Utf8NoBom -Path $patchFile.FullName -Content $patchJson

        $ocArguments = @(
            "patch", $Resource, $Name,
            "--type=merge",
            "--patch-file", $patchFile.FullName
        )
        if ($Namespace) {
            $ocArguments += @("-n", $Namespace)
        }

        $null = & oc @ocArguments 2>$null
        $patchExitCode = $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $patchFile.FullName `
            -Force -ErrorAction SilentlyContinue
    }

    if ($patchExitCode -ne 0) {
        Write-Err $FailureMessage
    }
}

function Get-PemCertificateBlocks {
    param(
        [string]$Path,
        [string]$Label
    )

    $pemText = [System.IO.File]::ReadAllText($Path)
    $pattern = '(?ms)^-----BEGIN CERTIFICATE-----\r?\n.*?^-----END CERTIFICATE-----\r?$'
    $certificateMatches = [regex]::Matches($pemText, $pattern)
    $remainingText = [regex]::Replace($pemText, $pattern, "")

    if ($certificateMatches.Count -eq 0 -or $remainingText -cnotmatch '^\s*$') {
        Write-Err "$Label must contain only complete PEM certificates: $Path"
    }

    foreach ($certificateMatch in $certificateMatches) {
        Write-Output $certificateMatch.Value
    }
}

function Test-CertificateBundle {
    param(
        [string]$Path,
        [string]$Label,
        [bool]$RequireCa = $false
    )

    $blocks = @(Get-PemCertificateBlocks -Path $Path -Label $Label)
    $index = 0
    foreach ($block in $blocks) {
        $index++
        $certificateFile = New-TemporaryFile
        try {
            Write-Utf8NoBom -Path $certificateFile.FullName -Content $block
            $certificateText = & $OPENSSL_COMMAND x509 `
                -in $certificateFile.FullName -noout -text 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Err "Certificate $index in $Label is not valid X.509"
            }

            $null = & $OPENSSL_COMMAND x509 -in $certificateFile.FullName `
                -noout -checkend 0 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Err "Certificate $index in $Label is expired"
            }

            if ($RequireCa -and (($certificateText -join "`n") -cnotmatch 'CA:\s*TRUE')) {
                Write-Err "Certificate $index in $Label is not a CA certificate"
            }
        } finally {
            Remove-Item -LiteralPath $certificateFile.FullName `
                -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-CertificateChainSha256 {
    param([string]$Path)

    $blocks = @(Get-PemCertificateBlocks `
        -Path $Path -Label "-IngressTlsCert")
    $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) `
        ([System.IO.Path]::GetRandomFileName())
    $null = [System.IO.Directory]::CreateDirectory($temporaryDirectory)

    try {
        $combinedDer = Join-Path $temporaryDirectory "chain.der"
        $outputStream = [System.IO.File]::Open(
            $combinedDer,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        try {
            for ($index = 0; $index -lt $blocks.Count; $index++) {
                $certificateFile = Join-Path $temporaryDirectory `
                    ("cert-{0:D4}.pem" -f ($index + 1))
                $certificateDer = Join-Path $temporaryDirectory `
                    ("cert-{0:D4}.der" -f ($index + 1))
                Write-Utf8NoBom -Path $certificateFile `
                    -Content $blocks[$index]

                $null = & $OPENSSL_COMMAND x509 -in $certificateFile `
                    -outform DER -out $certificateDer 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-Err "Could not normalize certificate $($index + 1) in the Ingress chain"
                }

                $certificateBytes = `
                    [System.IO.File]::ReadAllBytes($certificateDer)
                $outputStream.Write(
                    $certificateBytes,
                    0,
                    $certificateBytes.Length
                )
            }
        } finally {
            $outputStream.Dispose()
        }

        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $inputStream = [System.IO.File]::OpenRead($combinedDer)
        try {
            $hashBytes = $sha256.ComputeHash($inputStream)
        } finally {
            $inputStream.Dispose()
            $sha256.Dispose()
        }

        return ([System.BitConverter]::ToString($hashBytes) `
            -replace '-', '').ToLowerInvariant()
    } finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse `
            -Force -ErrorAction SilentlyContinue
    }
}

function Get-FileSha256 {
    param([string]$Path)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $inputStream = [System.IO.File]::OpenRead($Path)
    try {
        $hashBytes = $sha256.ComputeHash($inputStream)
        return ([System.BitConverter]::ToString($hashBytes) `
            -replace '-', '').ToLowerInvariant()
    } finally {
        $inputStream.Dispose()
        $sha256.Dispose()
    }
}

function Test-SuppliedIngressFilesUnchanged {
    if (-not (Test-Path -LiteralPath $INGRESS_TLS_CERT -PathType Leaf) -or
        -not (Test-Path -LiteralPath $INGRESS_TLS_KEY -PathType Leaf)) {
        Write-Err "The supplied Ingress certificate or private key is no longer readable"
    }

    $certificateFileSha256 = Get-FileSha256 -Path $INGRESS_TLS_CERT
    $keyFileSha256 = Get-FileSha256 -Path $INGRESS_TLS_KEY
    if ($certificateFileSha256 -cne $INGRESS_CERT_FILE_SHA256 -or
        $keyFileSha256 -cne $INGRESS_KEY_FILE_SHA256) {
        Write-Err "The supplied Ingress certificate or private key changed after validation; restart install with stable input files"
    }
}

function Test-PemPrivateKey {
    param([string]$Path)

    $pemText = [System.IO.File]::ReadAllText($Path)
    if ($pemText -cmatch '(?m)^-----BEGIN CERTIFICATE-----\r?$') {
        Write-Err "-IngressTlsKey must not contain certificates: $Path"
    }
    if ($pemText -cmatch '(?m)^-----BEGIN ENCRYPTED PRIVATE KEY-----\r?$' -or
        $pemText -cmatch '(?m)^Proc-Type:\s*4,ENCRYPTED\r?$') {
        Write-Err "-IngressTlsKey must be unencrypted: $Path"
    }

    $pattern = '(?ms)^-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----\r?\n.*?^-----END (?:[A-Z0-9]+ )?PRIVATE KEY-----\r?$'
    $keyMatches = [regex]::Matches($pemText, $pattern)
    $remainingText = [regex]::Replace($pemText, $pattern, "")
    if ($keyMatches.Count -ne 1 -or $remainingText -cnotmatch '^\s*$') {
        Write-Err "-IngressTlsKey must contain exactly one PEM private key"
    }

    $null = & $OPENSSL_COMMAND pkey -in $Path -noout -passin "pass:" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "The Ingress private key is invalid, encrypted, or unsupported"
    }
}

function Test-TlsOptions {
    Test-DnsLabel -Label "derived CI/CD namespace" -Value "$PRJ_PREFIX-cicd"
    Test-DnsLabel -Label "derived DEV namespace" -Value "$PRJ_PREFIX-dev"
    Test-DnsLabel -Label "derived STAGE namespace" -Value "$PRJ_PREFIX-stage"

    if ($CA_MODE -cnotin @("router", "file", "none")) {
        Write-Err "-CaMode must be one of: router, file, none"
    }

    if ($COMMAND -notin @("install", "start") -and $TLS_OPTIONS_EXPLICIT) {
        Write-Err "CA and Ingress TLS options are supported only with install or start"
    }

    if ($COMMAND -eq "start" -and
        ($CA_CONFIGMAP_EXPLICIT -or $INGRESS_TLS_CERT -or
            $INGRESS_TLS_KEY -or $INGRESS_TLS_SECRET_EXPLICIT)) {
        Write-Err "start accepts only -CaMode and -CaFile for its local Git connection"
    }

    if ($CA_MODE -eq "file") {
        if (-not $CA_FILE) {
            Write-Err "-CaFile is required with -CaMode file"
        }
        if (-not $CA_CONFIGMAP) {
            $script:CA_CONFIGMAP = "$PRJ_PREFIX-trusted-ca"
        }
    } elseif ($CA_FILE) {
        Write-Err "-CaFile can be used only with -CaMode file"
    } elseif ($CA_MODE -eq "router" -and -not $CA_CONFIGMAP) {
        $script:CA_CONFIGMAP = "custom-ca"
    }

    if ($CA_MODE -eq "none" -and $CA_CONFIGMAP_EXPLICIT) {
        Write-Err "-CaConfigMap cannot be used with -CaMode none"
    }

    if ([bool]$INGRESS_TLS_CERT -ne [bool]$INGRESS_TLS_KEY) {
        Write-Err "-IngressTlsCert and -IngressTlsKey must be provided together"
    }

    if (-not $INGRESS_TLS_CERT -and $INGRESS_TLS_SECRET_EXPLICIT) {
        Write-Err "-IngressTlsSecret requires a certificate/key pair"
    }

    if ($INGRESS_TLS_CERT -and -not $CA_MODE_EXPLICIT) {
        Write-Err "Select -CaMode file for a private CA or -CaMode none for a public/preconfigured CA"
    }

    if ($INGRESS_TLS_CERT -and $CA_MODE -eq "router") {
        Write-Err "A custom Ingress certificate requires -CaMode file or -CaMode none"
    }

    if ($CA_CONFIGMAP) {
        Test-DnsSubdomain -Label "-CaConfigMap" -Value $CA_CONFIGMAP
    }

    if ($CA_FILE) {
        $script:CA_FILE = Resolve-InputFile -Label "-CaFile" -Path $CA_FILE
        Resolve-OpenSslCommand
        Test-CertificateBundle -Path $CA_FILE -Label "-CaFile" -RequireCa $true
    }

    if ($INGRESS_TLS_CERT) {
        $script:INGRESS_TLS_CERT = Resolve-InputFile -Label "-IngressTlsCert" `
            -Path $INGRESS_TLS_CERT
        $script:INGRESS_TLS_KEY = Resolve-InputFile -Label "-IngressTlsKey" `
            -Path $INGRESS_TLS_KEY
        if (-not $OPENSSL_COMMAND) {
            Resolve-OpenSslCommand
        }
        Test-CertificateBundle -Path $INGRESS_TLS_CERT `
            -Label "-IngressTlsCert"
        Test-PemPrivateKey -Path $INGRESS_TLS_KEY

        $script:INGRESS_CERT_SHA256 = Get-CertificateChainSha256 `
            -Path $INGRESS_TLS_CERT
        if ($INGRESS_CERT_SHA256 -cnotmatch '^[0-9a-f]{64}$') {
            Write-Err "Could not calculate the SHA-256 digest of the Ingress certificate chain"
        }

        $script:INGRESS_CERT_FILE_SHA256 = Get-FileSha256 `
            -Path $INGRESS_TLS_CERT
        $script:INGRESS_KEY_FILE_SHA256 = Get-FileSha256 `
            -Path $INGRESS_TLS_KEY

        if (-not $INGRESS_TLS_SECRET) {
            $script:INGRESS_TLS_SECRET = "$PRJ_PREFIX-ingress-tls-$($INGRESS_CERT_SHA256.Substring(0, 12))"
        }
        Test-DnsSubdomain `
            -Label "-IngressTlsSecret" -Value $INGRESS_TLS_SECRET
    }
}

function Wait-ForOperator {
    param(
        [string]$SubscriptionName,
        [string]$Namespace = "openshift-operators",
        [int]$MaxWait = 600
    )

    Write-Info "Esperando a que el operador de la subscription $SubscriptionName esté completamente instalado..."

    $deadline = [DateTime]::UtcNow.AddSeconds($MaxWait)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $subOutput = oc --request-timeout=15s get `
                subscriptions.operators.coreos.com $SubscriptionName `
                -n $Namespace --ignore-not-found -o json 2>$null
            if ($subOutput) {
                $subscription = $subOutput | ConvertFrom-Json
                $csv = $subscription.status.installedCSV

                if ($csv -and $csv -ne "null" -and $csv -ne "") {
                    $csvOutput = oc --request-timeout=15s get csv $csv `
                        -n $Namespace --ignore-not-found -o json 2>$null
                    if ($csvOutput) {
                        $csvObj = $csvOutput | ConvertFrom-Json
                        $phase = $csvObj.status.phase

                        if ($phase -eq "Succeeded") {
                            Write-Info "Operador $SubscriptionName instalado correctamente (CSV: $csv)"
                            return
                        }

                        if ($phase -and $phase -ne "Succeeded") {
                            Write-Host -NoNewline "[$phase]"
                        }
                    }
                } else {
                    $installPlan = $subscription.status.installPlanRef.name
                    if ($installPlan -and $installPlan -ne "null" -and $installPlan -ne "") {
                        Write-Host -NoNewline "[installing]"
                    }
                }
            }
        } catch {
            # Subscription aún no existe o no tiene status
        }

        Wait-Seconds -Count 10
    }

    Write-Err "Timeout esperando a que el operador $SubscriptionName se instale (esperado: $MaxWait segundos)"
}

function Install-OpenShiftPipelines {
    $namespace = "openshift-operators"
    
    Write-Info "Instalando operador OpenShift Pipelines..."
    
    # Verificar si el namespace openshift-operators existe
    $nsExists = oc get ns $namespace --ignore-not-found -o name 2>$null
    if (-not $nsExists) {
        Write-Info "Creando namespace $namespace"
        oc create namespace $namespace | Out-Null
    }
    
    # Verificar si ya existe una subscription usando el CRD completo
    $subExists = oc get subscriptions.operators.coreos.com openshift-pipelines-operator-rh `
        -n $namespace --ignore-not-found -o name 2>$null
    if ($subExists) {
        Write-Info "El operador OpenShift Pipelines ya está suscrito"
    } else {
        # Crear OperatorGroup si no existe
        $ogExists = oc get operatorgroup -n $namespace -o name 2>$null
        if (-not $ogExists) {
            $operatorGroup = @"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-operators
  namespace: $namespace
spec:
  targetNamespaces: []
"@
            $operatorGroup | oc apply -f - | Out-Null
        }
        
        # Crear Subscription para OpenShift Pipelines
        $subscription = @"
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
"@
        $subscription | oc apply -f - | Out-Null
    }
    
    Wait-ForOperator -SubscriptionName "openshift-pipelines-operator-rh" -Namespace $namespace
}

function Install-OpenShiftGitOps {
    $namespace = "openshift-operators"
    
    Write-Info "Instalando operador OpenShift GitOps..."
    
    # Verificar si el namespace openshift-operators existe
    $nsExists = oc get ns $namespace --ignore-not-found -o name 2>$null
    if (-not $nsExists) {
        Write-Info "Creando namespace $namespace"
        oc create namespace $namespace | Out-Null
    }
    
    # Verificar si ya existe una subscription usando el CRD completo
    $subExists = oc get subscriptions.operators.coreos.com openshift-gitops-operator `
        -n $namespace --ignore-not-found -o name 2>$null
    if ($subExists) {
        Write-Info "El operador OpenShift GitOps ya está suscrito"
    } else {
        # Crear OperatorGroup si no existe
        $ogExists = oc get operatorgroup -n $namespace -o name 2>$null
        if (-not $ogExists) {
            $operatorGroup = @"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-operators
  namespace: $namespace
spec:
  targetNamespaces: []
"@
            $operatorGroup | oc apply -f - | Out-Null
        }
        
        # Crear Subscription para OpenShift GitOps
        $subscription = @"
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
"@
        $subscription | oc apply -f - | Out-Null
    }

    Wait-ForOperator -SubscriptionName "openshift-gitops-operator" -Namespace $namespace
}

function Test-IngressCertificateChain {
    param(
        [string]$CertificateChain,
        [string]$PrivateKey,
        [string]$IngressDomain,
        [string]$VerificationCaFile
    )

    $blocks = @(Get-PemCertificateBlocks `
        -Path $CertificateChain -Label "-IngressTlsCert")
    if ($blocks.Count -lt 2) {
        Write-Err "-IngressTlsCert must contain the leaf certificate followed by its root CA"
    }
    $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) `
        ([System.IO.Path]::GetRandomFileName())
    $null = [System.IO.Directory]::CreateDirectory($temporaryDirectory)

    try {
        $certificateFiles = @()
        for ($index = 0; $index -lt $blocks.Count; $index++) {
            $certificateFile = Join-Path $temporaryDirectory `
                ("cert-{0:D4}.pem" -f ($index + 1))
            Write-Utf8NoBom -Path $certificateFile -Content $blocks[$index]
            $certificateFiles += $certificateFile

            $certificateText = & $OPENSSL_COMMAND x509 `
                -in $certificateFile -noout -text 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Err "Certificate $($index + 1) in the Ingress chain is not valid X.509"
            }
            $isCa = ($certificateText -join "`n") -cmatch 'CA:\s*TRUE'
            if ($index -eq 0 -and $isCa) {
                Write-Err "The Ingress leaf certificate must not be a CA certificate"
            }
            if ($index -gt 0 -and -not $isCa) {
                Write-Err "Certificate $($index + 1) in the Ingress chain is not a CA certificate"
            }
        }

        $leafCertificate = $certificateFiles[0]
        $rootCertificate = $certificateFiles[$certificateFiles.Count - 1]

        for ($index = 0; $index -lt ($certificateFiles.Count - 1); $index++) {
            $currentIssuer = (& $OPENSSL_COMMAND x509 `
                -in $certificateFiles[$index] -noout -issuer `
                -nameopt RFC2253 2>$null) -join ""
            $nextSubject = (& $OPENSSL_COMMAND x509 `
                -in $certificateFiles[$index + 1] -noout -subject `
                -nameopt RFC2253 2>$null) -join ""
            $currentIssuer = ($currentIssuer -creplace '^issuer=\s*', '').Trim()
            $nextSubject = ($nextSubject -creplace '^subject=\s*', '').Trim()
            if ($currentIssuer -cne $nextSubject) {
                Write-Err "The Ingress certificate chain must be ordered leaf, intermediates, root"
            }

            $null = & $OPENSSL_COMMAND verify -partial_chain `
                -trusted $certificateFiles[$index + 1] `
                $certificateFiles[$index] 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Err "Certificate $($index + 1) is not signed by certificate $($index + 2) in the Ingress chain"
            }
        }

        $rootSubject = ((& $OPENSSL_COMMAND x509 -in $rootCertificate `
            -noout -subject -nameopt RFC2253 2>$null) -join "" `
            -creplace '^subject=\s*', '').Trim()
        $rootIssuer = ((& $OPENSSL_COMMAND x509 -in $rootCertificate `
            -noout -issuer -nameopt RFC2253 2>$null) -join "" `
            -creplace '^issuer=\s*', '').Trim()
        $null = & $OPENSSL_COMMAND verify -CAfile $rootCertificate `
            $rootCertificate 2>$null
        if ($rootSubject -cne $rootIssuer -or $LASTEXITCODE -ne 0) {
            Write-Err "The last certificate in the Ingress chain must be a self-signed root CA"
        }

        $sanOutput = & $OPENSSL_COMMAND x509 -in $leafCertificate `
            -noout -ext subjectAltName 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Unable to read subjectAltName from the Ingress certificate"
        }
        $expectedSan = "*.$IngressDomain"
        $sanPattern = '(?i)(?:^|[,\s])DNS:' +
            [regex]::Escape($expectedSan) + '(?=[,\s]|$)'
        if (-not [regex]::IsMatch(($sanOutput -join "`n"), $sanPattern)) {
            Write-Err "The leaf certificate must contain the exact wildcard SAN $expectedSan"
        }

        $certificatePublicPem = Join-Path $temporaryDirectory "certificate-public.pem"
        $certificatePublicDer = Join-Path $temporaryDirectory "certificate-public.der"
        $privateKeyPublicDer = Join-Path $temporaryDirectory "private-key-public.der"

        $null = & $OPENSSL_COMMAND x509 -in $leafCertificate `
            -pubkey -noout -out $certificatePublicPem 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Could not extract the public key from the Ingress certificate"
        }
        $null = & $OPENSSL_COMMAND pkey -pubin -in $certificatePublicPem `
            -outform DER -out $certificatePublicDer 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Could not normalize the public key from the Ingress certificate"
        }
        $null = & $OPENSSL_COMMAND pkey -in $PrivateKey -passin "pass:" `
            -pubout -outform DER -out $privateKeyPublicDer 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Could not derive the public key from the Ingress private key"
        }

        $certificatePublic = [System.Convert]::ToBase64String(
            [System.IO.File]::ReadAllBytes($certificatePublicDer)
        )
        $privateKeyPublic = [System.Convert]::ToBase64String(
            [System.IO.File]::ReadAllBytes($privateKeyPublicDer)
        )
        if ($certificatePublic -cne $privateKeyPublic) {
            Write-Err "The Ingress certificate and private key do not match"
        }

        if (-not $VerificationCaFile) {
            Write-Err "A trusted CA bundle is required to validate the Ingress certificate"
        }

        $untrustedBlocks = @()
        for ($index = 1; $index -lt $blocks.Count; $index++) {
            $untrustedBlocks += $blocks[$index]
        }

        $verifyArguments = @(
            "verify",
            "-purpose", "sslserver",
            "-verify_hostname", "tls-validation.$IngressDomain",
            "-CAfile", $VerificationCaFile
        )
        if ($untrustedBlocks.Count -gt 0) {
            $untrustedFile = Join-Path $temporaryDirectory "untrusted.pem"
            Write-Utf8NoBom -Path $untrustedFile `
                -Content (($untrustedBlocks -join "`n") + "`n")
            $verifyArguments += @("-untrusted", $untrustedFile)
        }
        $verifyArguments += $leafCertificate

        $null = & $OPENSSL_COMMAND @verifyArguments 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Err "The Ingress certificate chain is not trusted by the selected CA"
        }
    } finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse `
            -Force -ErrorAction SilentlyContinue
    }
}

function Test-IngressTlsPreflight {
    if (-not $INGRESS_TLS_CERT) {
        return
    }

    $controllerJson = oc --request-timeout=15s get `
        ingresscontroller.operator $INGRESS_CONTROLLER `
        -n openshift-ingress-operator -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $controllerJson) {
        Write-Err "IngressController/$INGRESS_CONTROLLER does not exist in openshift-ingress-operator"
    }
    $controller = $controllerJson | ConvertFrom-Json
    $ingressDomain = $controller.status.domain
    if (-not $ingressDomain) {
        Write-Err "IngressController/$INGRESS_CONTROLLER has no observed domain"
    }
    Test-DnsSubdomain `
        -Label "IngressController/$INGRESS_CONTROLLER domain" `
        -Value $ingressDomain

    $clusterTrustFile = $null
    $verificationCaFile = $CA_FILE
    try {
        if ($CA_MODE -eq "none") {
            $clusterTrustBundle = oc --request-timeout=15s get configmap `
                trusted-ca-bundle -n openshift-config-managed `
                -o jsonpath='{.data.ca-bundle\.crt}' 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $clusterTrustBundle) {
                Write-Err "Could not read the cluster managed trust bundle"
            }

            $clusterTrustFile = New-TemporaryFile
            Write-Utf8NoBom -Path $clusterTrustFile.FullName `
                -Content (($clusterTrustBundle -join "`n") + "`n")
            $verificationCaFile = $clusterTrustFile.FullName
        }

        Test-IngressCertificateChain `
            -CertificateChain $INGRESS_TLS_CERT `
            -PrivateKey $INGRESS_TLS_KEY `
            -IngressDomain $ingressDomain `
            -VerificationCaFile $verificationCaFile
    } finally {
        if ($clusterTrustFile) {
            Remove-Item -LiteralPath $clusterTrustFile.FullName `
                -Force -ErrorAction SilentlyContinue
        }
    }

    $null = oc create secret tls $INGRESS_TLS_SECRET `
        --cert=$INGRESS_TLS_CERT `
        --key=$INGRESS_TLS_KEY `
        -n openshift-ingress `
        --dry-run=client -o name 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "The Ingress certificate/key pair is invalid, encrypted, or does not match"
    }

    $null = Test-ExistingIngressTlsSecret -ValidationStage "during preflight"

    if (-not (Test-ClusterOperatorHealthy -Name "ingress") -or
        -not (Test-ClusterOperatorHealthy -Name "authentication") -or
        -not (Test-ClusterOperatorHealthy -Name "console")) {
        Write-Err "Ingress, authentication, and console operators must be stable before replacing the default Ingress certificate"
    }
}

function Test-ExistingIngressTlsSecret {
    param([string]$ValidationStage)

    Test-SuppliedIngressFilesUnchanged

    $existingSecretName = oc --request-timeout=15s get secret `
        $INGRESS_TLS_SECRET -n openshift-ingress `
        --ignore-not-found `
        -o jsonpath='{.metadata.name}' `
        2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Could not check Secret/$INGRESS_TLS_SECRET in openshift-ingress $ValidationStage"
    }
    if (-not $existingSecretName) {
        return $false
    }

    $existingSecretType = oc --request-timeout=15s get secret `
        $INGRESS_TLS_SECRET -n openshift-ingress `
        -o jsonpath='{.type}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Could not read the type of Secret/$INGRESS_TLS_SECRET"
    }
    $existingFingerprint = oc --request-timeout=15s get secret `
        $INGRESS_TLS_SECRET -n openshift-ingress `
        -o jsonpath='{.metadata.annotations.openshift-cicd-demo-certificate-chain-sha256}' `
        2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Could not read the digest annotation of Secret/$INGRESS_TLS_SECRET"
    }

    if (($existingSecretType -join "") -cne "kubernetes.io/tls" -or
        ($existingFingerprint -join "") -cne $INGRESS_CERT_SHA256) {
        Write-Err "Secret/$INGRESS_TLS_SECRET already exists without the expected TLS type and certificate-chain digest; choose an unused -IngressTlsSecret"
    }

    $existingCertificateBase64 = oc --request-timeout=15s get secret `
        $INGRESS_TLS_SECRET -n openshift-ingress `
        -o jsonpath='{.data.tls\.crt}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $existingCertificateBase64) {
        Write-Err "Could not read the certificate from Secret/$INGRESS_TLS_SECRET"
    }
    $existingKeyBase64 = oc --request-timeout=15s get secret `
        $INGRESS_TLS_SECRET -n openshift-ingress `
        -o jsonpath='{.data.tls\.key}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $existingKeyBase64) {
        Write-Err "Could not read the private key from Secret/$INGRESS_TLS_SECRET"
    }

    $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) `
        ([System.IO.Path]::GetRandomFileName())
    $null = [System.IO.Directory]::CreateDirectory($temporaryDirectory)
    $isWindows = [System.Environment]::OSVersion.Platform -eq `
        [System.PlatformID]::Win32NT
    if (-not $isWindows) {
        $null = & chmod 700 $temporaryDirectory 2>$null
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse `
                -Force -ErrorAction SilentlyContinue
            Write-Err "Could not restrict the temporary Ingress validation directory"
        }
    }

    try {
        $existingCertificate = Join-Path $temporaryDirectory "tls.crt"
        $existingKey = Join-Path $temporaryDirectory "tls.key"
        $suppliedKeyPublic = Join-Path $temporaryDirectory `
            "supplied-key-public.der"
        $existingKeyPublic = Join-Path $temporaryDirectory `
            "existing-key-public.der"

        try {
            $certificateBytes = [System.Convert]::FromBase64String(
                ($existingCertificateBase64 -join "")
            )
            $keyBytes = [System.Convert]::FromBase64String(
                ($existingKeyBase64 -join "")
            )
            [System.IO.File]::WriteAllBytes(
                $existingCertificate,
                $certificateBytes
            )
            [System.IO.File]::WriteAllBytes($existingKey, $keyBytes)
        } catch {
            Write-Err "Secret/$INGRESS_TLS_SECRET contains invalid TLS data"
        } finally {
            $existingKeyBase64 = $null
            $keyBytes = $null
        }

        if (-not $isWindows) {
            $null = & chmod 600 $existingKey 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Err "Could not restrict the temporary Ingress key file"
            }
        }

        $existingChainSha256 = Get-CertificateChainSha256 `
            -Path $existingCertificate
        if ($existingChainSha256 -cne $INGRESS_CERT_SHA256) {
            Write-Err "Secret/$INGRESS_TLS_SECRET contains a different certificate chain; choose an unused -IngressTlsSecret"
        }

        $null = & $OPENSSL_COMMAND pkey -in $INGRESS_TLS_KEY `
            -passin "pass:" -pubout -outform DER `
            -out $suppliedKeyPublic 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Could not derive the public key from the supplied Ingress key"
        }
        $null = & $OPENSSL_COMMAND pkey -in $existingKey `
            -passin "pass:" -pubout -outform DER `
            -out $existingKeyPublic 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Secret/$INGRESS_TLS_SECRET contains an invalid or encrypted private key"
        }

        $suppliedPublicBytes = [System.IO.File]::ReadAllBytes(
            $suppliedKeyPublic
        )
        $existingPublicBytes = [System.IO.File]::ReadAllBytes(
            $existingKeyPublic
        )
        if ([System.Convert]::ToBase64String($suppliedPublicBytes) -cne
            [System.Convert]::ToBase64String($existingPublicBytes)) {
            Write-Err "Secret/$INGRESS_TLS_SECRET contains a different private key; choose an unused -IngressTlsSecret"
        }

        return $true
    } finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse `
            -Force -ErrorAction SilentlyContinue
    }
}

function Configure-ClusterTrustedCA {
    if ($CA_MODE -eq "none") {
        Write-Info "Preservando proxy/cluster.spec.trustedCA sin cambios"
        return
    }

    $existingTrustedCA = oc --request-timeout=15s get proxy/cluster `
        -o jsonpath='{.spec.trustedCA.name}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "No se pudo consultar proxy/cluster.spec.trustedCA"
    }
    if ($existingTrustedCA -and $existingTrustedCA -ne $CA_CONFIGMAP) {
        Write-Err "proxy/cluster already references '$existingTrustedCA'. Use -CaMode none to preserve it or -CaConfigMap $existingTrustedCA with the complete bundle"
    }

    $existingConfigMap = oc --request-timeout=15s get configmap `
        $CA_CONFIGMAP -n openshift-config --ignore-not-found -o name 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Could not check ConfigMap/$CA_CONFIGMAP in openshift-config"
    }
    if ($existingConfigMap -and $existingTrustedCA -ne $CA_CONFIGMAP -and
        -not $CA_CONFIGMAP_EXPLICIT) {
        Write-Err "ConfigMap/$CA_CONFIGMAP already exists and is not selected by proxy/cluster; choose a different -ProjectPrefix or pass -CaConfigMap explicitly"
    }

    $tmpCaFile = $null
    $existingCaFile = $null
    try {
        if ($CA_MODE -eq "file") {
            Write-Info "Usando el bundle de CA proporcionado por el usuario"
            $caSourceFile = $CA_FILE
        } else {
            Write-Info "Extrayendo la CA interna desde openshift-ingress-operator/router-ca"
            $caBase64 = oc --request-timeout=15s get secret router-ca `
                -n openshift-ingress-operator `
                -o jsonpath='{.data.tls\.crt}' 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $caBase64) {
                Write-Err "No se pudo obtener openshift-ingress-operator/router-ca"
            }

            try {
                $caBytes = [System.Convert]::FromBase64String($caBase64)
            } catch {
                Write-Err "Error al decodificar la CA interna del router"
            }

            $tmpCaFile = New-TemporaryFile
            [System.IO.File]::WriteAllBytes($tmpCaFile.FullName, $caBytes)
            $caSourceFile = $tmpCaFile.FullName
        }

        if ($CA_MODE -eq "router" -and -not $CA_MODE_EXPLICIT -and
            $existingTrustedCA -eq $CA_CONFIGMAP -and $existingConfigMap) {
            $existingCaBundle = oc --request-timeout=15s get configmap `
                $CA_CONFIGMAP -n openshift-config `
                -o jsonpath='{.data.ca-bundle\.crt}' 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $existingCaBundle) {
                Write-Err "Could not read ConfigMap/$CA_CONFIGMAP in openshift-config"
            }

            $existingCaFile = New-TemporaryFile
            Write-Utf8NoBom -Path $existingCaFile.FullName `
                -Content (($existingCaBundle -join "`n") + "`n")
            if (-not (Test-CertificateBundleContains `
                -SourceFile $caSourceFile `
                -TargetFile $existingCaFile.FullName)) {
                Write-Err "The existing $CA_CONFIGMAP does not contain the current router CA; use -CaMode none to preserve it or pass -CaMode router explicitly to refresh it"
            }

            Wait-ForClusterTrustedCA `
                -CaSourceFile $existingCaFile.FullName `
                -MaxWait 1200 -InitialDelay 0
            Write-Info "El bundle existente $CA_CONFIGMAP contiene la CA actual del router"
            return
        }

        if (-not (Test-ClusterOperatorHealthy -Name "network") -or
            -not (Test-ClusterOperatorHealthy -Name "machine-config") -or
            -not (Test-MachineConfigPoolsHealthy)) {
            Write-Err "Network, machine-config, and MachineConfigPools must be stable before changing proxy/cluster.spec.trustedCA"
        }

        Write-Info "Creando o actualizando ConfigMap $CA_CONFIGMAP en openshift-config"
        $configMapYaml = oc create configmap $CA_CONFIGMAP `
            "--from-file=ca-bundle.crt=$caSourceFile" `
            -n openshift-config --dry-run=client -o yaml
        if ($LASTEXITCODE -ne 0 -or -not $configMapYaml) {
            Write-Err "No se pudo generar el bundle de CA del cluster"
        }
        $configMapYaml | oc apply -f - | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Err "No se pudo crear o actualizar el bundle de CA del cluster"
        }

        Invoke-OcMergePatch `
            -Resource "proxy.config.openshift.io" `
            -Name "cluster" `
            -Patch @{
                spec = @{
                    trustedCA = @{
                        name = $CA_CONFIGMAP
                    }
                }
            } `
            -FailureMessage "No se pudo actualizar proxy/cluster.spec.trustedCA"

        Wait-ForClusterTrustedCA -CaSourceFile $caSourceFile -MaxWait 1200
    } finally {
        if ($tmpCaFile) {
            Remove-Item -LiteralPath $tmpCaFile.FullName -Force -ErrorAction SilentlyContinue
        }
        if ($existingCaFile) {
            Remove-Item -LiteralPath $existingCaFile.FullName `
                -Force -ErrorAction SilentlyContinue
        }
    }

}

function Wait-ForIngressController {
    param([int]$MaxWait = 600)

    $deadline = [DateTime]::UtcNow.AddSeconds($MaxWait)
    Write-Info "Esperando a que IngressController/$INGRESS_CONTROLLER esté disponible..."
    Wait-Seconds -Count 20
    $healthySamples = 0

    while ([DateTime]::UtcNow -lt $deadline) {
        $ingressControllerJson = oc --request-timeout=15s get `
            ingresscontroller.operator $INGRESS_CONTROLLER `
            -n openshift-ingress-operator -o json 2>$null
        if ($LASTEXITCODE -eq 0 -and $ingressControllerJson) {
            $ingressControllerObject = $ingressControllerJson | ConvertFrom-Json
            $configuredSecret = $ingressControllerObject.spec.defaultCertificate.name
            $availableReplicas = [int]$ingressControllerObject.status.availableReplicas
            $availableCondition = $ingressControllerObject.status.conditions |
                Where-Object { $_.type -eq "Available" } |
                Select-Object -First 1
            $progressingCondition = $ingressControllerObject.status.conditions |
                Where-Object { $_.type -eq "Progressing" } |
                Select-Object -First 1
            $degradedCondition = $ingressControllerObject.status.conditions |
                Where-Object { $_.type -eq "Degraded" } |
                Select-Object -First 1

            if ($ingressControllerObject.metadata.generation -eq
                    $ingressControllerObject.status.observedGeneration -and
                $configuredSecret -eq $INGRESS_TLS_SECRET -and
                $availableReplicas -gt 0 -and
                $availableCondition.status -eq "True" -and
                $progressingCondition.status -eq "False" -and
                $degradedCondition.status -eq "False" -and
                (Test-ClusterOperatorHealthy -Name "ingress") -and
                (Test-ClusterOperatorHealthy -Name "authentication") -and
                (Test-ClusterOperatorHealthy -Name "console")) {
                $healthySamples++
                if ($healthySamples -ge 2) {
                    Write-Info "IngressController/$INGRESS_CONTROLLER usa el Secret $INGRESS_TLS_SECRET y está estable"
                    return
                }
            } else {
                $healthySamples = 0
            }
        } else {
            $healthySamples = 0
        }

        Wait-Seconds -Count 10
    }

    Write-Err "Timeout esperando la reconciliación de IngressController/$INGRESS_CONTROLLER"
}

function Configure-IngressTls {
    if (-not $INGRESS_TLS_CERT) {
        return
    }

    if (-not (Test-ClusterOperatorHealthy -Name "ingress") -or
        -not (Test-ClusterOperatorHealthy -Name "authentication") -or
        -not (Test-ClusterOperatorHealthy -Name "console")) {
        Write-Err "Ingress, authentication, and console operators are not stable immediately before replacing the default Ingress certificate"
    }

    if (Test-ExistingIngressTlsSecret `
        -ValidationStage "immediately before Ingress configuration") {
        Write-Info "Reutilizando el Secret TLS versionado $INGRESS_TLS_SECRET"
    } else {
        Write-Info "Creando el Secret TLS versionado $INGRESS_TLS_SECRET en openshift-ingress"
        $null = oc create secret tls $INGRESS_TLS_SECRET `
            --cert=$INGRESS_TLS_CERT `
            --key=$INGRESS_TLS_KEY `
            -n openshift-ingress 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Err "No se pudo crear el Secret TLS del Ingress Controller"
        }

        $null = oc annotate secret $INGRESS_TLS_SECRET `
            -n openshift-ingress `
            "$INGRESS_CERT_ANNOTATION=$INGRESS_CERT_SHA256" `
            --overwrite 2>$null
        if ($LASTEXITCODE -ne 0) {
            $null = oc --request-timeout=15s delete secret `
                $INGRESS_TLS_SECRET -n openshift-ingress `
                --ignore-not-found 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Err "No se pudo registrar el digest de la cadena; el Secret recién creado fue eliminado"
            }
            Write-Err "No se pudo registrar el digest de la cadena ni eliminar Secret/$INGRESS_TLS_SECRET"
        }
    }

    Invoke-OcMergePatch `
        -Resource "ingresscontroller.operator.openshift.io" `
        -Name $INGRESS_CONTROLLER `
        -Namespace "openshift-ingress-operator" `
        -Patch @{
            spec = @{
                defaultCertificate = @{
                    name = $INGRESS_TLS_SECRET
                }
            }
        } `
        -FailureMessage "No se pudo configurar el certificado de IngressController/$INGRESS_CONTROLLER"

    Wait-ForIngressController -MaxWait 600
}

function Get-PemCertificateBodies {
    param([string]$Text)

    $pattern = '(?ms)^-----BEGIN CERTIFICATE-----\r?\n(?<body>.*?)^-----END CERTIFICATE-----\r?$'
    $certificateMatches = [regex]::Matches($Text, $pattern)
    foreach ($certificateMatch in $certificateMatches) {
        Write-Output ($certificateMatch.Groups['body'].Value -replace '\s', '')
    }
}

function Test-CertificateBundleContains {
    param(
        [string]$SourceFile,
        [string]$TargetFile
    )

    $sourceBodies = @(Get-PemCertificateBodies `
        -Text ([System.IO.File]::ReadAllText($SourceFile)))
    $targetBodies = @(Get-PemCertificateBodies `
        -Text ([System.IO.File]::ReadAllText($TargetFile)))
    if ($sourceBodies.Count -eq 0) {
        return $false
    }

    foreach ($body in $sourceBodies) {
        if ($targetBodies -cnotcontains $body) {
            return $false
        }
    }

    return $true
}

function Test-ManagedBundleContainsCA {
    param([string]$CaSourceFile)

    $managedBundle = oc --request-timeout=15s get configmap `
        trusted-ca-bundle -n openshift-config-managed `
        -o jsonpath='{.data.ca-bundle\.crt}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $managedBundle) {
        return $false
    }

    $managedBundleFile = New-TemporaryFile
    try {
        Write-Utf8NoBom -Path $managedBundleFile.FullName `
            -Content (($managedBundle -join "`n") + "`n")
        return Test-CertificateBundleContains `
            -SourceFile $CaSourceFile `
            -TargetFile $managedBundleFile.FullName
    } finally {
        Remove-Item -LiteralPath $managedBundleFile.FullName `
            -Force -ErrorAction SilentlyContinue
    }
}

function Test-ClusterOperatorHealthy {
    param([string]$Name)

    $operatorJson = oc --request-timeout=15s get clusteroperator $Name `
        -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $operatorJson) {
        return $false
    }

    $operator = $operatorJson | ConvertFrom-Json
    $available = $operator.status.conditions |
        Where-Object { $_.type -eq "Available" } |
        Select-Object -First 1
    $progressing = $operator.status.conditions |
        Where-Object { $_.type -eq "Progressing" } |
        Select-Object -First 1
    $degraded = $operator.status.conditions |
        Where-Object { $_.type -eq "Degraded" } |
        Select-Object -First 1

    return $available.status -eq "True" -and
        $progressing.status -eq "False" -and
        $degraded.status -eq "False"
}

function Test-MachineConfigPoolsHealthy {
    $poolJson = oc --request-timeout=15s get machineconfigpool -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $poolJson) {
        return $false
    }

    $pools = ($poolJson | ConvertFrom-Json).items
    if (-not $pools) {
        return $false
    }

    foreach ($pool in $pools) {
        if ($pool.spec.paused -eq $true -or
            $pool.metadata.generation -ne $pool.status.observedGeneration -or
            $pool.status.readyMachineCount -ne $pool.status.machineCount -or
            $pool.status.updatedMachineCount -ne $pool.status.machineCount -or
            $pool.status.unavailableMachineCount -ne 0 -or
            $pool.status.degradedMachineCount -ne 0) {
            return $false
        }
    }

    return $true
}

function Wait-ForClusterTrustedCA {
    param(
        [string]$CaSourceFile,
        [int]$MaxWait = 1200,
        [int]$InitialDelay = 60
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($MaxWait)
    Write-Info "Esperando la propagación del bundle de CA del cluster..."
    if ($InitialDelay -gt 0) {
        Wait-Seconds -Count $InitialDelay
    }
    $healthySamples = 0

    while ([DateTime]::UtcNow -lt $deadline) {
        $configuredCa = oc --request-timeout=15s get proxy/cluster `
            -o jsonpath='{.spec.trustedCA.name}' 2>$null

        if ($LASTEXITCODE -eq 0 -and $configuredCa -eq $CA_CONFIGMAP -and
            (Test-ManagedBundleContainsCA -CaSourceFile $CaSourceFile) -and
            (Test-ClusterOperatorHealthy -Name "network") -and
            (Test-ClusterOperatorHealthy -Name "machine-config") -and
            (Test-MachineConfigPoolsHealthy)) {
            $healthySamples++
            if ($healthySamples -ge 2) {
                Write-Info "El bundle $CA_CONFIGMAP fue propagado y los operadores están estables"
                return
            }
        } else {
            $healthySamples = 0
        }

        Wait-Seconds -Count 10
    }

    Write-Err "Timeout esperando la propagación de $CA_CONFIGMAP después de $MaxWait segundos"
}

function Wait-ForPipelinesAsCodeRoute {
    param(
        [string]$Namespace = "openshift-pipelines",
        [int]$MaxWait = 600
    )

    $routeName = "pipelines-as-code-controller"
    Write-Info "Esperando a que la ruta $routeName esté disponible en el namespace $Namespace..."

    $deadline = [DateTime]::UtcNow.AddSeconds($MaxWait)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            # Intentar obtener la ruta primero en openshift-pipelines
            $routeOutput = oc --request-timeout=15s get route $routeName `
                -n $Namespace --ignore-not-found -o jsonpath='{.spec.host}' 2>$null
            if ($routeOutput -and $routeOutput -ne "null" -and $routeOutput -ne "") {
                Write-Info "Ruta $routeName disponible en $Namespace (host: $routeOutput)"
                return
            }

            # Si no está en openshift-pipelines, intentar en pipelines-as-code
            if ($Namespace -eq "openshift-pipelines") {
                $routeOutput = oc --request-timeout=15s get route $routeName `
                    -n pipelines-as-code --ignore-not-found `
                    -o jsonpath='{.spec.host}' 2>$null
                if ($routeOutput -and $routeOutput -ne "null" -and $routeOutput -ne "") {
                    Write-Info "Ruta $routeName disponible en pipelines-as-code (host: $routeOutput)"
                    return
                }
            }
        } catch {
            # Ruta aún no existe
        }

        Wait-Seconds -Count 10
    }

    Write-Err "Timeout esperando a que la ruta $routeName esté disponible (esperado: $MaxWait segundos)"
}

function Wait-ForArgoCdRoute {
    param(
        [string]$Namespace,
        [int]$MaxWait = 600
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($MaxWait)
    while ([DateTime]::UtcNow -lt $deadline) {
        $route = oc --request-timeout=15s get route argocd-server `
            -n $Namespace --ignore-not-found -o name 2>$null
        if ($LASTEXITCODE -eq 0 -and $route) {
            Write-Info "La ruta argocd-server está disponible en $Namespace"
            return
        }
        Wait-Seconds -Count 10
    }

    Write-Err "Timeout esperando la ruta argocd-server después de $MaxWait segundos"
}

function Wait-ForTaskRun {
    param(
        [string]$Name,
        [string]$Namespace,
        [int]$MaxWait = 600
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($MaxWait)
    while ([DateTime]::UtcNow -lt $deadline) {
        $taskRunJson = oc --request-timeout=15s get taskrun $Name `
            -n $Namespace --ignore-not-found -o json 2>$null
        if ($LASTEXITCODE -eq 0 -and $taskRunJson) {
            $taskRun = $taskRunJson | ConvertFrom-Json
            $condition = $taskRun.status.conditions |
                Where-Object { $_.type -eq "Succeeded" } |
                Select-Object -First 1

            if ($condition.status -eq "True") {
                Write-Info "TaskRun $Name completado correctamente"
                return
            }
            if ($condition.status -eq "False") {
                Write-Err "TaskRun $Name falló; revise su estado sin imprimir valores de Secrets"
            }
        }

        Write-Host "waiting for Gitea init TaskRun to complete..."
        Wait-Seconds -Count 10
    }

    Write-Err "Timeout esperando TaskRun/$Name después de $MaxWait segundos"
}

function Wait-ForGitRepository {
    param(
        [string]$Uri,
        [int]$MaxWait = 600
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($MaxWait)
    while ([DateTime]::UtcNow -lt $deadline) {
        $curlArguments = @(
            "--silent",
            "--fail",
            "--location",
            "--connect-timeout", "5",
            "--max-time", "15"
        )
        switch ($CA_MODE) {
            "router" {
                $curlArguments += "--insecure"
            }
            "file" {
                $curlArguments += @("--cacert", $CA_FILE)
            }
            "none" { }
        }
        $curlArguments += "$Uri/info/refs?service=git-upload-pack"

        $null = & $CURL_COMMAND @curlArguments 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Info "El repositorio de Gitea está disponible"
            return
        }
        Wait-Seconds -Count 10
    }

    Write-Err "Timeout esperando el repositorio de Gitea después de $MaxWait segundos"
}

function Command-Install {
    $ocVersion = oc version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "no oc binary found"
    }
    Assert-GitCommand
    Resolve-CurlCommand

    Test-IngressTlsPreflight

    Write-Info "Configurando la confianza TLS del cluster..."
    Configure-ClusterTrustedCA

    Write-Info "Configurando el certificado TLS del Ingress Controller..."
    Configure-IngressTls

    
    Write-Info "Instalando operadores requeridos..."
    Install-OpenShiftPipelines
    Install-OpenShiftGitOps
    
    Write-Info "Esperando a que la ruta pipelines-as-code-controller esté disponible..."
    Wait-ForPipelinesAsCodeRoute -Namespace "openshift-pipelines"
    
    Write-Info "Creating namespaces $cicd_prj, $dev_prj, $stage_prj"
    
    $ns = oc get ns $cicd_prj --ignore-not-found -o name 2>$null
    if (-not $ns) {
        oc new-project $cicd_prj | Out-Null
    }
    
    $ns = oc get ns $dev_prj --ignore-not-found -o name 2>$null
    if (-not $ns) {
        oc new-project $dev_prj | Out-Null
    }
    
    $ns = oc get ns $stage_prj --ignore-not-found -o name 2>$null
    if (-not $ns) {
        oc new-project $stage_prj | Out-Null
    }
    
    Write-Info "Configure service account permissions for pipeline"
    # Verificar y agregar políticas solo si no existen (idempotente)
    $rbDev = oc get rolebinding -n $dev_prj 2>$null | Select-String "system:serviceaccount:$cicd_prj:pipeline"
    if (-not $rbDev) {
        oc policy add-role-to-user edit "system:serviceaccount:$cicd_prj:pipeline" -n $dev_prj 2>$null | Out-Null
    }
    $rbStage = oc get rolebinding -n $stage_prj 2>$null | Select-String "system:serviceaccount:$cicd_prj:pipeline"
    if (-not $rbStage) {
        oc policy add-role-to-user edit "system:serviceaccount:$cicd_prj:pipeline" -n $stage_prj 2>$null | Out-Null
    }
    $rbCicdDev = oc get rolebinding -n $cicd_prj 2>$null | Select-String "system:serviceaccount:$dev_prj:default"
    if (-not $rbCicdDev) {
        oc policy add-role-to-user system:image-puller "system:serviceaccount:$dev_prj:default" -n $cicd_prj 2>$null | Out-Null
    }
    $rbCicdStage = oc get rolebinding -n $cicd_prj 2>$null | Select-String "system:serviceaccount:$stage_prj:default"
    if (-not $rbCicdStage) {
        oc policy add-role-to-user system:image-puller "system:serviceaccount:$stage_prj:default" -n $cicd_prj 2>$null | Out-Null
    }
    
    Write-Info "Deploying CI/CD infra to $cicd_prj namespace"
    oc apply -f infra -n $cicd_prj | Out-Null
    
    $giteaHostname = oc get route gitea -o template --template='{{.spec.host}}' -n $cicd_prj
    
    Write-Info "Initiatlizing git repository in Gitea and configuring webhooks"
    $webhookUrl = oc get route pipelines-as-code-controller -n pipelines-as-code -o template --template="{{.spec.host}}" --ignore-not-found 2>$null
    if (-not $webhookUrl) {
        $webhookUrl = oc get route pipelines-as-code-controller -n openshift-pipelines -o template --template="{{.spec.host}}"
    }
    
    # Crear o actualizar configmap de Gitea (idempotente)
    $giteaConfig = Get-Content "config/gitea-configmap.yaml" -Raw
    $giteaConfig = $giteaConfig -replace '@HOSTNAME', $giteaHostname
    $giteaConfig | oc apply -f - -n $cicd_prj | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "No se pudo aplicar la configuración de Gitea"
    }
    oc rollout restart deployment/gitea -n $cicd_prj | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "No se pudo reiniciar Gitea con la configuración actualizada"
    }
    try {
        oc rollout status deployment/gitea -n $cicd_prj --timeout=5m | Out-Null
    } catch {
        Write-Err "El deployment de Gitea no quedó disponible en 5 minutos"
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Err "El deployment de Gitea no quedó disponible en 5 minutos"
    }
    
    # Crear taskrun siempre con oc create (tiene generateName, no se puede usar apply)
    Write-Info "Creando TaskRun para inicializar Gitea..."
    $taskrunConfig = Get-Content "config/gitea-init-taskrun.yaml" -Raw
    $taskrunConfig = $taskrunConfig -replace '@webhook-url@', "https://$webhookUrl"
    $taskrunConfig = $taskrunConfig -replace '@gitea-url@', "https://$giteaHostname"
    $taskrunName = $taskrunConfig |
        oc create -f - -n $cicd_prj `
            -o "jsonpath={.metadata.name}" 2>$null
    $taskrunCreateExit = $LASTEXITCODE
    $taskrunName = "$taskrunName".Trim()
    if ($taskrunCreateExit -ne 0 -or -not $taskrunName) {
        Write-Err "No se pudo crear el TaskRun de inicialización de Gitea"
    }
    
    Write-Info "Esperando a que el TaskRun $taskrunName termine su ejecución..."
    Wait-ForTaskRun -Name $taskrunName -Namespace $cicd_prj -MaxWait 600
    
    Write-Host "Waiting for source code to be imported to Gitea..."
    Wait-ForGitRepository `
        -Uri "https://$giteaHostname/gitea/spring-petclinic" `
        -MaxWait 600
    
    Wait-Seconds -Count 10
    Start-Sleep -Seconds 10
    
    Write-Info "Updating pipelinerun values for the demo environment"
    $tmpDir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_.FullName }
    $locationPushed = $false
    try {
        Push-Location $tmpDir
        $locationPushed = $true

        # Clonar solo si el directorio no existe o está vacío
        if (-not (Test-Path spring-petclinic) -or (Get-ChildItem spring-petclinic -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
            $gitExitCode = Invoke-GitNetwork -Arguments @(
                "clone",
                "https://$giteaHostname/gitea/spring-petclinic"
            )
            if ($gitExitCode -ne 0) {
                Write-Err "No se pudo clonar spring-petclinic desde Gitea"
            }
        }
        Set-Location spring-petclinic
        git config user.email "openshift-pipelines@redhat.com"
        git config user.name "openshift-pipelines"
        
        # Verificar si ya está actualizado antes de hacer cambios
        $buildYamlContent = Get-Content ".tekton/build.yaml" -Raw -ErrorAction SilentlyContinue
        if ($buildYamlContent -and $buildYamlContent -notmatch "$giteaHostname/gitea/spring-petclinic-config") {
            $buildYaml = $buildYamlContent
            $buildYaml = $buildYaml -replace 'https://github.com/siamaksade/spring-petclinic-config', "https://$giteaHostname/gitea/spring-petclinic-config"
            Set-Content -Path ".tekton/build.yaml" -Value $buildYaml

            git add .tekton/build.yaml
            if ($LASTEXITCODE -ne 0) {
                Write-Err "No se pudo preparar la actualización de Pipelines-as-Code"
            }
            git commit -m "Updated manifests git url" 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Err "No se pudo crear el commit de Pipelines-as-Code"
            }
            $remotes = @(git remote)
            if ($LASTEXITCODE -ne 0) {
                Write-Err "No se pudieron consultar los remotos Git"
            }
            if ($remotes -contains "auth-origin") {
                git remote remove auth-origin | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Err "No se pudo eliminar el remoto temporal de Gitea"
                }
            }
            git remote add auth-origin "https://gitea:openshift@$giteaHostname/gitea/spring-petclinic" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Err "No se pudo configurar el remoto temporal de Gitea"
            }
            $gitExitCode = Invoke-GitNetwork `
                -Arguments @("push", "auth-origin", "cicd-demo") -Quiet
            if ($gitExitCode -ne 0) {
                Write-Err "No se pudo publicar la configuración actualizada en Gitea"
            }
        } else {
            Write-Info "El repositorio ya está actualizado con la URL correcta"
        }
    } finally {
        if ($locationPushed) {
            Pop-Location
        }
        Remove-Item -Path $tmpDir -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
    
    Write-Info "Configuring pipelines-as-code"
    # Verificar si el Repository ya existe
    $repoExists = oc get repository spring-petclinic -n $cicd_prj `
        --ignore-not-found -o name 2>$null
    if ($repoExists) {
        Write-Info "El Repository pipelines-as-code ya está configurado"
    } else {
        $pacRepository = @"
---
apiVersion: "pipelinesascode.tekton.dev/v1alpha1"
kind: Repository
metadata:
  name: spring-petclinic
  namespace: "$cicd_prj"
spec:
  url: https://$giteaHostname/gitea/spring-petclinic
  git_provider:
    user: git
    url: https://$giteaHostname
    secret:
      name: "gitea"
      key: token
    webhook_secret:
      name: "gitea"
      key: "webhook"
"@

        $pacRepository | oc apply -f - -n $cicd_prj | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Err "No se pudo configurar el Repository de Pipelines-as-Code"
        }
    }
    
    Wait-Seconds -Count 10
    
    Write-Info "Configure Argo CD"
    
    $argocdAppPatch = @"
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dev-spring-petclinic
spec:
  destination:
    namespace: "$dev_prj"
  source:
    repoURL: https://$giteaHostname/gitea/spring-petclinic-config
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: stage-spring-petclinic
spec:
  destination:
    namespace: "$stage_prj"
  source:
    repoURL: https://$giteaHostname/gitea/spring-petclinic-config
"@
    
    $tmpArgoFile = Join-Path $SCRIPT_DIR "argo/tmp-argocd-app-patch.yaml"
    Set-Content -Path $tmpArgoFile -Value $argocdAppPatch
    oc apply -k argo -n $cicd_prj | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "No se pudo aplicar la configuración de Argo CD"
    }
    
    Write-Info "Wait for Argo CD route..."
    Wait-ForArgoCdRoute -Namespace $cicd_prj -MaxWait 600
    
    Write-Info "Grants permissions to ArgoCD instances to manage resources in target namespaces"
    # Aplicar labels solo si no existen o son diferentes (idempotente)
    $currentLabelDev = oc get ns $dev_prj -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/managed-by}' 2>$null
    if ($currentLabelDev -ne $cicd_prj) {
        oc label ns $dev_prj "argocd.argoproj.io/managed-by=$cicd_prj" --overwrite | Out-Null
    }
    $currentLabelStage = oc get ns $stage_prj -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/managed-by}' 2>$null
    if ($currentLabelStage -ne $cicd_prj) {
        oc label ns $stage_prj "argocd.argoproj.io/managed-by=$cicd_prj" --overwrite | Out-Null
    }
    
    oc project $cicd_prj | Out-Null
    
    $sonarqubeHost = oc get route sonarqube -o template --template='{{.spec.host}}' -n $cicd_prj
    $nexusHost = oc get route nexus -o template --template='{{.spec.host}}' -n $cicd_prj
    $argocdHost = oc get route argocd-server -o template --template='{{.spec.host}}' -n $cicd_prj
    
    Write-Host @"

############################################################################
############################################################################

  Demo is installed! Give it a few minutes to finish deployments and then:

  1) Go to spring-petclinic Git repository in Gitea:
     https://$giteaHostname/gitea/spring-petclinic.git

  2) Log into Gitea with username/password: gitea/openshift

  3) Edit a file in the repository and commit to trigger the pipeline (alternatively, create a pull-request)

  4) Check the pipeline run logs in Dev Console or Tekton CLI:

    `$ opc pac logs -n $cicd_prj


  You can find further details at:

  Gitea Git Server: https://$giteaHostname/explore/repos
  SonarQube: https://$sonarqubeHost
  Sonatype Nexus: https://$nexusHost
  Argo CD:  http://$argocdHost  [login with OpenShift credentials]

############################################################################
############################################################################
"@
}

function Command-Start {
    $null = oc version 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "no oc binary found"
    }
    Assert-GitCommand
    $giteaHostname = oc --request-timeout=15s get route gitea `
        -o template --template='{{.spec.host}}' -n $cicd_prj `
        --ignore-not-found 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $giteaHostname) {
        Write-Err "No se pudo obtener la ruta de Gitea en $cicd_prj"
    }
    Write-Info "Pushing a change to https://$giteaHostname/gitea/spring-petclinic-config"
    
    $tmpDir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_.FullName }
    $locationPushed = $false
    try {
        Push-Location $tmpDir
        $locationPushed = $true

        $gitExitCode = Invoke-GitNetwork -Arguments @(
            "clone",
            "https://$giteaHostname/gitea/spring-petclinic"
        )
        if ($gitExitCode -ne 0) {
            Write-Err "No se pudo clonar spring-petclinic desde Gitea"
        }
        Set-Location spring-petclinic
        git config user.email "openshift-pipelines@redhat.com"
        git config user.name "openshift-pipelines"

        Add-Content -Path "readme.md" -Value "   "
        git add readme.md
        if ($LASTEXITCODE -ne 0) {
            Write-Err "No se pudo preparar el cambio de demostración"
        }
        git commit -m "Updated readme.md"
        if ($LASTEXITCODE -ne 0) {
            Write-Err "No se pudo crear el commit de demostración"
        }
        git remote add auth-origin "https://gitea:openshift@$giteaHostname/gitea/spring-petclinic"
        if ($LASTEXITCODE -ne 0) {
            Write-Err "No se pudo configurar el remoto temporal de Gitea"
        }
        $gitExitCode = Invoke-GitNetwork `
            -Arguments @("push", "auth-origin", "cicd-demo") -Quiet
        if ($gitExitCode -ne 0) {
            Write-Err "No se pudo publicar el cambio de demostración en Gitea"
        }
    } finally {
        if ($locationPushed) {
            Pop-Location
        }
        Remove-Item -Path $tmpDir -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
}

function Command-Uninstall {
    oc delete project $dev_prj $stage_prj $cicd_prj
}

# Parse arguments
$argsList = $args
$i = 0
while ($i -lt $argsList.Length) {
    $arg = $argsList[$i]
    switch -Wildcard ($arg) {
        { $_ -in "install", "uninstall", "start", "help" } {
            if ($COMMAND_SET) {
                Write-Err "Error: only one command can be specified"
            }
            $COMMAND = $_
            $COMMAND_SET = $true
            $i++
            continue
        }
        { $_ -in "-p", "--project-prefix", "-ProjectPrefix", "--ProjectPrefix" } {
            if ($i + 1 -lt $argsList.Length -and
                -not ([string]$argsList[$i + 1]).StartsWith("-")) {
                $PRJ_PREFIX = $argsList[$i + 1]
                $dev_prj = "$PRJ_PREFIX-dev"
                $stage_prj = "$PRJ_PREFIX-stage"
                $cicd_prj = "$PRJ_PREFIX-cicd"
                $i += 2
                continue
            } else {
                Write-Err "Error: $arg requires a value"
            }
        }
        { $_ -in "-CaMode", "--ca-mode" } {
            if ($i + 1 -lt $argsList.Length -and
                -not ([string]$argsList[$i + 1]).StartsWith("-")) {
                $CA_MODE = $argsList[$i + 1]
                $CA_MODE_EXPLICIT = $true
                $TLS_OPTIONS_EXPLICIT = $true
                $i += 2
                continue
            } else {
                Write-Err "Error: $arg requires a value"
            }
        }
        { $_ -in "-CaFile", "--ca-file" } {
            if ($i + 1 -lt $argsList.Length -and
                -not ([string]$argsList[$i + 1]).StartsWith("-")) {
                $CA_FILE = $argsList[$i + 1]
                $TLS_OPTIONS_EXPLICIT = $true
                $i += 2
                continue
            } else {
                Write-Err "Error: $arg requires a value"
            }
        }
        { $_ -in "-CaConfigMap", "--ca-configmap" } {
            if ($i + 1 -lt $argsList.Length -and
                -not ([string]$argsList[$i + 1]).StartsWith("-")) {
                $CA_CONFIGMAP = $argsList[$i + 1]
                $CA_CONFIGMAP_EXPLICIT = $true
                $TLS_OPTIONS_EXPLICIT = $true
                $i += 2
                continue
            } else {
                Write-Err "Error: $arg requires a value"
            }
        }
        { $_ -in "-IngressTlsCert", "--ingress-tls-cert" } {
            if ($i + 1 -lt $argsList.Length -and
                -not ([string]$argsList[$i + 1]).StartsWith("-")) {
                $INGRESS_TLS_CERT = $argsList[$i + 1]
                $TLS_OPTIONS_EXPLICIT = $true
                $i += 2
                continue
            } else {
                Write-Err "Error: $arg requires a value"
            }
        }
        { $_ -in "-IngressTlsKey", "--ingress-tls-key" } {
            if ($i + 1 -lt $argsList.Length -and
                -not ([string]$argsList[$i + 1]).StartsWith("-")) {
                $INGRESS_TLS_KEY = $argsList[$i + 1]
                $TLS_OPTIONS_EXPLICIT = $true
                $i += 2
                continue
            } else {
                Write-Err "Error: $arg requires a value"
            }
        }
        { $_ -in "-IngressTlsSecret", "--ingress-tls-secret" } {
            if ($i + 1 -lt $argsList.Length -and
                -not ([string]$argsList[$i + 1]).StartsWith("-")) {
                $INGRESS_TLS_SECRET = $argsList[$i + 1]
                $INGRESS_TLS_SECRET_EXPLICIT = $true
                $TLS_OPTIONS_EXPLICIT = $true
                $i += 2
                continue
            } else {
                Write-Err "Error: $arg requires a value"
            }
        }
        "--" {
            if ($i + 1 -lt $argsList.Length) {
                Write-Err "Error: unexpected argument $($argsList[$i + 1])"
            }
            $i = $argsList.Length
            continue
        }
        "-*" {
            Write-Err "Error: Unsupported flag $arg"
        }
        default {
            Write-Err "Error: unexpected argument $arg"
        }
    }
}

# Main execution
Test-TlsOptions
Set-Location $SCRIPT_DIR

if ($COMMAND -eq "help") {
    Command-Help
    exit 0
}

$functionName = "Command-$COMMAND"
if (-not (Test-ValidCommand -CommandName $COMMAND)) {
    Write-Err "invalid command '$COMMAND'"
}

& $functionName
