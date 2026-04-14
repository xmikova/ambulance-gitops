param (
    $cluster ,
    $namespace,
    $installFlux = $true
)

if ( -not $cluster ) {
    $cluster = "localhost"
}

if ( -not $namespace ) {
    $namespace = "wac-hospital"
}

$ProjectRoot = "${PSScriptRoot}/.."
echo "ScriptRoot is $PSScriptRoot"
echo "ProjectRoot is $ProjectRoot"

$clusterRoot = "$ProjectRoot/clusters/$cluster"


$ErrorActionPreference = "Stop"

$context = kubectl config current-context

if ((Get-Host).version.major -lt 7 ){
    Write-Host -Foreground red "PowerShell Version must be minimum of 7, please install latest version of PowerShell. Current Version is $((Get-Host).version)"
    exit -10
}
$pwsv=$((Get-Host).version)
try {if(Get-Command sops){$sopsVersion=$(sops -v)}}
Catch {
    Write-Host -Foreground red "sops CLI must be installed, use 'choco install sops' to install it before continuing."
    exit -11
}

# check if $cluster folder exists
if (-not (Test-Path -Path "$clusterRoot" -PathType Container)) {
    Write-Host -Foreground red "Cluster folder $cluster does not exist"
    exit -12
}

$banner = @"
THIS IS A FAST DEPLOYMENT SCRIPT FOR DEVELOPERS!
---

The script shall be running **only on fresh local cluster** **!
After initialization, it **uses gitops** controlled by installed flux cd controller.
To do some local fine tuning get familiar with flux, kustomize, and kubernetes

Verify that your context is coresponding to your local development cluster:

* Your kubectl *context* is **$context**.
* You are installing *cluster* **$cluster**.
* *PowerShell* version is **$pwsv**.
* *Mozilaa SOPS* version is **$sopsVersion**.
* You got *private SOPS key* for development setup.
"@

$banner = ($banner | ConvertFrom-MarkDown -AsVt100EncodedString)
Show-Markdown -InputObject $banner
Write-Host "$banner"
$correct = Read-Host "Are you sure to continue? (y/n)"

if ($correct -ne 'y')
{
    Write-Host -Foreground red "Exiting script due to the user selection"
    exit -1
}

function read-password($prompt="Password", $defaultPassword="")
{
    $p = "${prompt} [${defaultPassword}]"
    $password = Read-Host -MaskInput -Prompt $p
    if (-not $password) { $password = $defaultPassword}
    return $password
}

$agekey = read-password "Enter master key of SOPS AGE (for developers)"

# create a namespace
Write-Host -Foreground blue "Creating namespace $namespace"
kubectl create namespace $namespace
Write-Host -Foreground green "Created namespace $namespace"

# generate AGE key pair and create a secret for it
Write-Host -Foreground blue "Creating sops-age private secret in the namespace ${namespace}"

kubectl delete secret sops-age --namespace "${namespace}"
kubectl create secret generic sops-age --namespace "${namespace}" --from-literal=age.agekey="$agekey"

Write-Host -Foreground green "Created sops-age private secret in the namespace ${namespace}"

# unencrypt gitops-repo secrets to push it into cluster
Write-Host -Foreground blue "Creating gitops-repo secret in the namespace ${namespace}"

$patSecret = "$clusterRoot/secrets/params/repository-pat.env"
if (-not (Test-Path -Path $patSecret)) {
    $patSecret = "$clusterRoot/../localhost/secrets/params/gitops-repo.env"
    if (-not (Test-Path -Path $patSecret)) {
        Write-Host -Foreground red "gitops-repo secret not found in $clusterRoot/secrets/params/gitops-repo.env or $clusterRoot/../localhost/secrets/params/gitops-repo.env"
        exit -13
    }
}

$oldKey=$env:SOPS_AGE_KEY
$env:SOPS_AGE_KEY=$agekey
$envs=sops --decrypt $patSecret

# check for error exit code
if ($LASTEXITCODE -ne 0) {
    Write-Host -Foreground red "Failed to decrypt gitops-repo secret"
    exit -14
}

# read environments from env
$envs | Foreach-Object {
    $env = $_.split("=")
    $envName = $env[0]
    $envValue = $env[1]
    if ($envName -eq "username") {
        $username = $envValue
    }
    if ($envName -eq "password") {
        $password = $envValue
    }
}
$env:SOPS_AGE_KEY="$oldKey"
$agekey=""
kubectl delete secret repository-pat --namespace $namespace
kubectl create secret generic  repository-pat `
  --namespace $namespace `
  --from-literal username=$username `
  --from-literal password=$password `

$username=""
$password=""
Write-Host -Foreground green "Created gitops-repo secret in the namespace ${namespace}"

if($installFlux)
{
    Write-Host -Foreground blue "Deploying the Flux CD controller"
    # first ensure crds exists when applying the repos
    kubectl apply -k $ProjectRoot/infrastructure/fluxcd --wait

    if ($LASTEXITCODE -ne 0) {
        Write-Host -Foreground red "Failed to deploy fluxcd"
        exit -15
    }

    Write-Host -Foreground blue "Flux CD controller deployed"
}

Write-Host -Foreground blue "Deploying the cluster manifests"
kubectl apply -k $clusterRoot --wait
Write-Host -Foreground green "Bootstrapping process is done, check the status of the GitRepository and Kustomization resource in namespace ${namespace} for reconcilation updates"
