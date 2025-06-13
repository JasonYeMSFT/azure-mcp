<#
.SYNOPSIS
Updates package README.md for publishing to docs.microsoft.com

.DESCRIPTION
Given a PackageInfo .json file, format the package README.md file with metadata
and other information needed to release reference docs:

* Adjust README.md content to include metadata
* Insert the package verison number in the README.md title
* Copy file to the appropriate location in the documentation repository
* Copy PackageInfo .json file to the metadata location in the reference docs
  repository. This enables the Docs CI build to onboard packages which have not
  shipped and for which there are no entries in the metadata CSV files.

.PARAMETER PackageInfoJsonLocations
List of locations of the artifact information .json file. This is usually stored
in build artifacts under packages/PackageInfo/<package-name>.json. Can also be
a single item.

.PARAMETER DocRepoLocation
Location of the root of the docs.microsoft.com reference doc location. Further
path information is provided by $GetDocsMsMetadataForPackageFn

.PARAMETER Language
Programming language to supply to metadata

.PARAMETER RepoId
GitHub repository ID of the SDK. Typically of the form: 'Azure/azure-sdk-for-js'

#>

param(
  [Parameter(Mandatory = $true)]
  [array]$PackageInfoJsonLocations,

  [Parameter(Mandatory = $true)]
  [string]$DocRepoLocation,

  [Parameter(Mandatory = $false)]
  [string]$Language,

  [Parameter(Mandatory = $false)]
  [string]$RepoId,

  [Parameter(Mandatory = $false)]
  [string]$PackageSourceOverride
)
Set-StrictMode -Version 3
. (Join-Path $PSScriptRoot common.ps1)
. (Join-Path $PSScriptRoot Helpers Metadata-Helpers.ps1)

$releaseReplaceRegex = "(https://github.com/$RepoId/(?:blob|tree)/)(?:master|main)"
$TITLE_REGEX = "(\#\s+(?<filetitle>Azure .+? (?:client|plugin|shared) library for (?:JavaScript|Java|Python|\.NET|C)))"

function GetAdjustedReadmeContent($ReadmeContent, $PackageInfo, $PackageMetadata) {
  # The $PackageMetadata could be $null if there is no associated metadata entry
  # based on how the metadata CSV is filtered
  $service = $PackageInfo.ServiceDirectory.ToLower()
  if ($PackageMetadata -and $PackageMetadata.MSDocService -and 'placeholder' -ine $PackageMetadata.MSDocService) {
    # Use MSDocService in csv metadata to override the service directory
    # TODO: Use taxonomy for service name -- https://github.com/Azure/azure-sdk-tools/issues/1442
    $service = $PackageMetadata.MSDocService
  }
  Write-Host "The service of package: $service"
  # Generate the release tag for use in link substitution
  $tag = "$($PackageInfo.Name)_$($PackageInfo.Version)"
  Write-Host "The tag of package: $tag"
  $date = Get-Date -Format "MM/dd/yyyy"


  $foundTitle = ""
  if ($ReadmeContent -match $TITLE_REGEX) {
    $ReadmeContent = $ReadmeContent -replace $TITLE_REGEX, "`${0} - version $($PackageInfo.Version) `n"
    $foundTitle = $matches["filetitle"]
  }

  # If this is not a daily dev package, perform link replacement
  if (!$packageInfo.DevVersion) {
    $replacementPattern = "`${1}$tag"
    $ReadmeContent = $ReadmeContent -replace $releaseReplaceRegex, $replacementPattern
  }

  $header = @"
---
title: $foundTitle
keywords: Azure, $Language, SDK, API, $($PackageInfo.Name), $service
ms.date: $date
ms.topic: reference
ms.devlang: $Language
ms.service: $service
---
"@

  $ReadmeContent = $ReadmeContent -replace "https://docs.microsoft.com(/en-us)?/?", "/"
  return "$header`n$ReadmeContent"
}

function GetPackageInfoJson ($packageInfoJsonLocation) {
  if (!(Test-Path $packageInfoJsonLocation)) {
    LogWarning "Package metadata not found for $packageInfoJsonLocation"
    return
  }

  $packageInfoJson = Get-Content $packageInfoJsonLocation -Raw
  $packageInfo = ConvertFrom-Json $packageInfoJson
  if ($GetDocsMsDevLanguageSpecificPackageInfoFn -and (Test-Path "Function:$GetDocsMsDevLanguageSpecificPackageInfoFn")) {
    $packageInfo = &$GetDocsMsDevLanguageSpecificPackageInfoFn $packageInfo $PackageSourceOverride
  }
  # Default: use the dev version from package info as the version for
  # downstream processes
  if ($packageInfo.DevVersion) {
    $packageInfo.Version = $packageInfo.DevVersion
  }
  return $packageInfo
}

function UpdateDocsMsMetadataForPackage($packageInfo, $packageMetadataName) {

  $originalVersion = [AzureEngSemanticVersion]::ParseVersionString($packageInfo.Version)
  $packageMetadataArray = (Get-CSVMetadata).Where({ $_.Package -eq $packageInfo.Name -and $_.Hide -ne 'true' -and $_.New -eq 'true' })
  if ($packageInfo.Group) {
    $packageMetadataArray = ($packageMetadataArray).Where({ $_.GroupId -eq $packageInfo.Group })
  }
  if ($packageMetadataArray.Count -eq 0) {
    LogWarning "Could not retrieve metadata for $($packageInfo.Name) from metadata CSV. Using best effort defaults."
    $packageMetadata = $null
  }
  elseif ($packageMetadataArray.Count -gt 1) {
    LogWarning "Multiple metadata entries for $($packageInfo.Name) in metadata CSV. Using first entry."
    $packageMetadata = $packageMetadataArray[0]
  }
  else {
    $packageMetadata = $packageMetadataArray[0]
  }

  # Copy package info file to the docs repo
  $docsMsMetadata = &$GetDocsMsMetadataForPackageFn $packageInfo
  $readMePath = $docsMsMetadata.LatestReadMeLocation
  $metadataMoniker = 'latest'
  if ($originalVersion -and $originalVersion.IsPrerelease) {
    $metadataMoniker = 'preview'
    $readMePath = $docsMsMetadata.PreviewReadMeLocation
  }
  $packageInfoLocation = Join-Path $DocRepoLocation "metadata/$metadataMoniker"
  if (Test-Path "$packageInfoLocation/$packageMetadataName") {
    Write-Host "The docs metadata json $packageMetadataName exists, updating..."
    $docsMetadata = Get-Content "$packageInfoLocation/$packageMetadataName" -Raw | ConvertFrom-Json
    foreach ($property in $docsMetadata.PSObject.Properties) {
      if ($packageInfo.PSObject.Properties.Name -notcontains $property.Name) {
        $packageInfo | Add-Member -MemberType $property.MemberType -Name $property.Name -Value $property.Value -Force
      }
    }
  }
  else {
    Write-Host "The docs metadata json $packageMetadataName does not exist, creating a new one to docs repo..."
    New-Item -ItemType Directory -Path $packageInfoLocation -Force
  }
  $packageInfoJson = ConvertTo-Json $packageInfo -Depth 100
  Set-Content `
    -Path $packageInfoLocation/$packageMetadataName `
    -Value $packageInfoJson

  # Update Readme Content
  if (!$packageInfo.ReadMePath -or !(Test-Path $packageInfo.ReadMePath)) {
    Write-Warning "$($packageInfo.Name) does not have Readme file. Skipping update readme."
    return
  }

  $readmeContent = Get-Content $packageInfo.ReadMePath -Raw
  $outputReadmeContent = ""
  if ($readmeContent) {
    $outputReadmeContent = GetAdjustedReadmeContent $readmeContent $packageInfo $packageMetadata
  }

  $suffix = $docsMsMetadata.Suffix
  $readMeName = "$($docsMsMetadata.DocsMsReadMeName.ToLower())-readme${suffix}.md"

  $readmeLocation = Join-Path $DocRepoLocation $readMePath $readMeName

  Set-Content -Path $readmeLocation -Value $outputReadmeContent
}

$allSucceeded = $true
foreach ($packageInfoLocation in $PackageInfoJsonLocations) {

  $packageInfo =  GetPackageInfoJson $packageInfoLocation

  if ($ValidateDocsMsPackagesFn -and (Test-Path "Function:$ValidateDocsMsPackagesFn")) {
    Write-Host "Validating the packages..."
    # This calls a function named "Validate-${Language}-DocMsPackages"
    # declared in common.ps1, implemented in Language-Settings.ps1
    $isValid = &$ValidateDocsMsPackagesFn `
      -PackageInfos $packageInfo `
      -PackageSourceOverride $PackageSourceOverride `
      -DocRepoLocation $DocRepoLocation

    if (!$isValid) {
      Write-Host "Package validation failed for package: $packageInfoLocation"
      $allSucceeded = $false

      # Skip the later call to UpdateDocsMsMetadataForPackage because this
      # package has not passed validation
      continue
    }
  }

  Write-Host "Updating metadata for package: $packageInfoLocation"
  $packageMetadataName = Split-Path $packageInfoLocation -Leaf
  # Convert package metadata json file to metadata json property.
  UpdateDocsMsMetadataForPackage $packageInfo $packageMetadataName
}

# Set a variable which will be used by the pipeline later to fail the build if
# any packages failed validation
if ($allSucceeded) {
  Write-Host "##vso[task.setvariable variable=DocsMsPackagesAllValid;]$true"
} else {
  Write-Host "##vso[task.setvariable variable=DocsMsPackagesAllValid;]$false"
}
