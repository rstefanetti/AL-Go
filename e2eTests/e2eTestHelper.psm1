﻿$githubOwner = "githubOwner"
$token = "token"
$repository = "repo"

function SetTokenAndRepository {
    Param(
        [string] $githubOwner,
        [string] $token,
        [string] $repository,
        [switch] $github
    )

    $script:githubOwner = $githubOwner
    $script:token = $token
    $script:repository = $repository

    if ($github) {
        invoke-git config --global user.email "$githubOwner@users.noreply.github.com"
        invoke-git config --global user.name "$githubOwner"
        invoke-git config --global hub.protocol https
        invoke-git config --global core.autocrlf true

        $ENV:GITHUB_TOKEN = $token
        gh auth login --with-token
    }
    else {
        $token | gh auth login --with-token
    }
}

function ConvertTo-HashTable() {
    Param(
        [parameter(ValueFromPipeline)]
        [PSCustomObject] $object
    )
    $ht = @{}
    if ($object) {
        $object.PSObject.Properties | Foreach { $ht[$_.Name] = $_.Value }
    }
    $ht
}

function Get-PlainText {
    Param(
        [parameter(ValueFromPipeline, Mandatory = $true)]
        [System.Security.SecureString] $SecureString
    )
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString);
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr);
    }
    finally {
        [Runtime.InteropServices.Marshal]::FreeBSTR($bstr);
    }
}

function Add-PropertiesToJsonFile {
    Param(
        [string] $jsonFile,
        [hashTable] $properties
    )

    Write-Host -ForegroundColor Yellow "`nAdd Properties to $([System.IO.Path]::GetFileName($jsonFile))"
    Write-Host "Properties"
    $properties | Out-Host

    $json = Get-Content $jsonFile -Encoding UTF8 | ConvertFrom-Json | ConvertTo-HashTable
    $properties.Keys | ForEach-Object {
        $json."$_" = $properties."$_"
    }
    $json | ConvertTo-Json | Set-Content $jsonFile -Encoding UTF8

    CommitAndPush -commitMessage "Update $([System.IO.Path]::GetFileName($jsonFile))"
}


function DisplayTokenAndRepository {
    Write-Host "Token: $token"
    Write-Host "Rrepo: $repository"
}

function RunWorkflow {
    Param(
        [string] $name,
        [hashtable] $parameters = @{},
        [switch] $wait,
        [string] $branch = "main"
    )

    Write-Host -ForegroundColor Yellow "`nRun workflow $name in $repository"
    if ($parameters -and $parameters.Count -gt 0) {
        Write-Host "Parameters:"
        Write-Host ($parameters | ConvertTo-Json)
    }

    $headers = @{ 
      "Accept" = "application/vnd.github.v3+json"
      "Authorization" = "token $token"
    }

    $rate = ((Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri "https://api.github.com/rate_limit").Content | ConvertFrom-Json).rate
    $percent = [int]($rate.remaining*100/$rate.limit)
    Write-Host "$($rate.remaining) API calls remaining out of $($rate.limit) ($percent%)"
    if ($percent -lt 10) {
        $resetTimeStamp = ([datetime] '1970-01-01Z').AddSeconds($rate.reset)
        $waitTime = $resetTimeStamp.Subtract([datetime]::Now)
        Write-Host "Less than 10% API calls left, waiting for $($waitTime.TotalSeconds) seconds for limits to reset."
        Start-Sleep -seconds $waitTime.TotalSeconds+1
    }

    $url = "https://api.github.com/repos/$repository/actions/workflows"
    $workflows = (Invoke-WebRequest -UseBasicParsing -Method Get -Headers $headers -Uri $url | ConvertFrom-Json).workflows
    $workflow = $workflows | Where-Object { $_.Name -eq $name }
    
    $url = "https://api.github.com/repos/$repository/actions/runs"
    $previousrun = (Invoke-WebRequest -UseBasicParsing -Method Get -Headers $headers -Uri $url | ConvertFrom-Json).workflow_runs | Where-Object { $_.workflow_id -eq $workflow.id } | Select-Object -First 1
    
    $url = "https://api.github.com/repos/$repository/actions/workflows/$($workflow.id)/dispatches"
    $body = @{
        "ref" = "refs/heads/$branch"
        "inputs" = $parameters
    }
    Invoke-WebRequest -UseBasicParsing -Method Post -Headers $headers -Uri $url -Body ($body | ConvertTo-Json) | Out-Null

    Write-Host -NoNewline "Queuing."
    do {
        Start-Sleep -Seconds 10
        $url = "https://api.github.com/repos/$repository/actions/runs"
        $run = (Invoke-WebRequest -UseBasicParsing -Method Get -Headers $headers -Uri $url | ConvertFrom-Json).workflow_runs | Where-Object { $_.workflow_id -eq $workflow.id } | Select-Object -First 1
        Write-Host -NoNewline "."
    } until (($run) -and ((!$previousrun) -or ($run.id -ne $previousrun.id)))
    Write-Host
    $runid = $run.id
    Write-Host "Run URL: https://github.com/$repository/actions/runs/$runid"
    if ($wait) {
        WaitWorkflow -runid $run.id
    }
    $run
}

function WaitWorkflow {
    Param(
        [string] $runid
    )

    $headers = @{ 
        "Accept" = "application/vnd.github.v3+json"
        "Authorization" = "token $token"
    }

    $status = ""
    do {
        Start-Sleep -Seconds 30
        $url = "https://api.github.com/repos/$repository/actions/runs/$runid"
        $run = (Invoke-WebRequest -UseBasicParsing -Method Get -Headers $headers -Uri $url | ConvertFrom-Json)
        if ($run.status -ne $status) {
            if ($status) { Write-Host }
            $status = $run.status
            Write-Host -NoNewline "$status"
        }
        Write-Host -NoNewline "."
    } while ($run.status -eq "queued" -or $run.status -eq "in_progress")
    Write-Host
    Write-Host $run.conclusion
    if ($run.conclusion -ne "Success") {
        throw "Workflow $name failed, url = $($run.html_url)"
    }
}

function SetRepositorySecret {
    Param(
        [string] $name,
        [secureString] $value
    )

    gh secret set $name -b ($value | Get-PlainText) --repo $repository
}

function invoke-gh {
    Param(
        [parameter(mandatory = $true, position = 0)][string] $command,
        [parameter(mandatory = $false, position = 1, ValueFromRemainingArguments = $true)] $remaining
    )

    Write-Host "gh $command $remaining"
    $ErrorActionPreference = "SilentlyContinue"
    gh $command $remaining
    $ErrorActionPreference = "Stop"
    if ($lastexitcode) { throw "gh $command error" }
}

function invoke-git {
    Param(
        [parameter(mandatory = $true, position = 0)][string] $command,
        [parameter(mandatory = $false, position = 1, ValueFromRemainingArguments = $true)] $remaining
    )

    Write-Host "git $command $remaining"
    $ErrorActionPreference = "SilentlyContinue"
    git $command $remaining
    $ErrorActionPreference = "Stop"
    if ($lastexitcode) { throw "git $command error" }
}

function CreateRepository {
    Param(
        [string] $template,
        [string] $templateBranch = "main",
        [string] $templatePath,
        [switch] $private,
        [string] $branch = "main"
    )

    $tempPath = [System.IO.Path]::GetTempPath()
    $path = Join-Path $tempPath ([GUID]::NewGuid().ToString())
    New-Item $path -ItemType Directory | Out-Null
    Set-Location $path
    if ($private) {
        Write-Host -ForegroundColor Yellow "`nCreating private repository $repository (based on $template@$templateBranch)"
        invoke-gh repo create $repository --private --clone
    }
    else {
        Write-Host -ForegroundColor Yellow "`nCreating public repository $repository (based on $template@$templateBranch)"
        invoke-gh repo create $repository --public --clone
    }
    Start-Sleep -seconds 10
    Set-Location '*'

    if ($template) {
        $templateUrl = "$template/archive/refs/heads/$templateBranch.zip"
        $zipFileName = Join-Path $tempPath "$([GUID]::NewGuid().ToString()).zip"
        [System.Net.WebClient]::new().DownloadFile($templateUrl, $zipFileName)
        
        $tempRepoPath = Join-Path $tempPath ([GUID]::NewGuid().ToString())
        Expand-Archive -Path $zipFileName -DestinationPath $tempRepoPath
        Copy-Item (Join-Path (Get-Item "$tempRepoPath\*").FullName '*') -Destination . -Recurse -Force
        Remove-Item -Path $tempRepoPath -Force -Recurse
        Remove-Item -Path $zipFileName -Force
    }
    if ($templatePath) {
        Write-Host "$(Join-Path $templatePath '*')"

        Copy-Item (Join-Path $templatePath '*') -Destination . -Recurse -Force
    }

    invoke-git add *
    invoke-git commit --allow-empty -m 'init'
    invoke-git branch -M $branch
    if ($githubOwner -and $token) {
        invoke-git remote set-url origin "https://$($githubOwner):$token@github.com/$repository.git"
    }
    invoke-git push --set-upstream origin $branch
    Start-Sleep -seconds 10
}

function Pull {
    Param(
        [string] $branch = "main"
    )

    invoke-git pull origin $branch | Out-Host
}

function CommitAndPush {
    Param(
        [string] $serverUrl,
        [string] $commitMessage = "commitmessage"
    )

    invoke-git add *
    invoke-git commit --allow-empty -m "'$commitMessage'"
    invoke-git push $serverUrl | Out-Host
}

function MergePRandPull {
    Param(
        [string] $branch = "main"
    )

    $phs = @(invoke-gh pr list --repo $repository)
    if ($phs.Count -eq 0) {
        throw "No Pull Request was created"
    }
    elseif ($phs.Count -gt 1) {
        throw "More than one Pull Request exists"
    }
    $prid = $phs.Split("`t")[0]
    Write-Host -ForegroundColor Yellow "`nMerge Pull Request $prid into repository $repository"
    invoke-gh pr merge $prid --squash --delete-branch --repo $repository | Out-Host
    Pull -branch $branch
}

function RemoveRepository {
    Param(
        [string] $repository,
        [string] $path = ""
    )

    if ($repository) {
        Write-Host -ForegroundColor Yellow "`nRemoving repository $repository"
        invoke-gh repo delete $repository --confirm | Out-Host
    }

    if ($path) {
        if (-not $path.StartsWith("$([System.IO.Path]::GetTempPath())",[StringComparison]::InvariantCultureIgnoreCase)) {
            throw "$path is not temppath"
        }
        else {
            Set-Location ([System.IO.Path]::GetTempPath())
            Remove-Item $path -Recurse -Force
        }
    }
}

. (Join-Path $PSScriptRoot "Workflows\Run-AddExistingAppOrTestApp.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-CICD.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-CreateApp.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-CreateOnlineDevelopmentEnvironment.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-CreateRelease.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-CreateTestApp.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-IncrementVersionNumber.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-PublishToEnvironment.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-UpdateAlGoSystemFiles.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-TestCurrent.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-TestNextMinor.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-TestNextMajor.ps1")

. (Join-Path $PSScriptRoot "Test-Functions.ps1")
