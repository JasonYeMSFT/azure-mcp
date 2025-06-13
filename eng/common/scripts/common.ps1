# cSpell:ignore Apireview
# cSpell:ignore Onboarded
$RepoRoot = Resolve-Path "${PSScriptRoot}..\..\..\.."
$EngDir = Join-Path $RepoRoot "eng"
$EngCommonDir = Join-Path $EngDir "common"
$EngCommonScriptsDir = Join-Path $EngCommonDir "scripts"
$EngScriptsDir = Join-Path $EngDir "scripts"

# Import required scripts
. (Join-Path $EngCommonScriptsDir SemVer.ps1)
. (Join-Path $EngCommonScriptsDir ChangeLog-Operations.ps1)
. (Join-Path $EngCommonScriptsDir Package-Properties.ps1)
. (Join-Path $EngCommonScriptsDir logging.ps1)
. (Join-Path $EngCommonScriptsDir Invoke-GitHubAPI.ps1)
. (Join-Path $EngCommonScriptsDir Invoke-DevOpsAPI.ps1)
. (Join-Path $EngCommonScriptsDir artifact-metadata-parsing.ps1)
. (Join-Path $EngCommonScriptsDir "Helpers" git-helpers.ps1)
. (Join-Path $EngCommonScriptsDir "Helpers" Package-Helpers.ps1)
. (Join-Path $EngCommonScriptsDir "Helpers" CommandInvocation-Helpers.ps1)

# Setting expected from common languages settings
$Language = "Unknown"
$PackageRepository = "Unknown"
$packagePattern = "Unknown"
$MetadataUri = "Unknown"

# Whether the language repo supports automatically loading .env file generated from TestResources scripts.
$SupportsTestResourcesDotenv = $false

# Import common language settings
$EngScriptsLanguageSettings = Join-path $EngScriptsDir "Language-Settings.ps1"
if (Test-Path $EngScriptsLanguageSettings) {
  . $EngScriptsLanguageSettings
}

if (!(Get-Variable -Name "LanguageShort" -ValueOnly -ErrorAction "Ignore"))
{
  $LanguageShort = $Language
}

if (!(Get-Variable -Name "LanguageDisplayName" -ValueOnly -ErrorAction "Ignore"))
{
  $LanguageDisplayName = $Language
}

# Transformed Functions
# Expected to be set in eng/scripts/Language-Settings.ps1
$GetPackageInfoFromRepoFn = "Get-${Language}-PackageInfoFromRepo"
$GetPackageInfoFromPackageFileFn = "Get-${Language}-PackageInfoFromPackageFile"
$PublishGithubIODocsFn = "Publish-${Language}-GithubIODocs"
$UpdateDocsMsPackagesFn = "Update-${Language}-DocsMsPackages"
$GetDocsMsMetadataForPackageFn = "Get-${Language}-DocsMsMetadataForPackage"
$GetDocsMsDevLanguageSpecificPackageInfoFn = "Get-${Language}-DocsMsDevLanguageSpecificPackageInfo"
$GetGithubIoDocIndexFn = "Get-${Language}-GithubIoDocIndex"
$FindArtifactForApiReviewFn = "Find-${Language}-Artifacts-For-Apireview"
$TestProxyTrustCertFn = "Import-Dev-Cert-${Language}"
$ValidateDocsMsPackagesFn = "Validate-${Language}-DocMsPackages"
$GetOnboardedDocsMsPackagesFn = "Get-${Language}-OnboardedDocsMsPackages"
$GetOnboardedDocsMsPackagesForMonikerFn = "Get-${Language}-OnboardedDocsMsPackagesForMoniker"
$GetDocsMsTocDataFn = "Get-${Language}-DocsMsTocData"
$GetDocsMsTocChildrenForManagementPackagesFn = "Get-${Language}-DocsMsTocChildrenForManagementPackages"
$UpdateDocsMsTocFn = "Get-${Language}-UpdatedDocsMsToc"
$GetPackageLevelReadmeFn = "Get-${Language}-PackageLevelReadme"
$GetRepositoryLinkFn = "Get-${Language}-RepositoryLink"
$GetEmitterAdditionalOptionsFn = "Get-${Language}-EmitterAdditionalOptions"
$GetEmitterNameFn = "Get-${Language}-EmitterName"
$GetDirectoriesForGenerationFn = "Get-${Language}-DirectoriesForGeneration"
$UpdateGeneratedSdksFn = "Update-${Language}-GeneratedSdks"
$IsApiviewStatusCheckRequiredFn = "Get-${Language}-ApiviewStatusCheckRequirement"
$AdditionalValidationPackagesFromPackageSetFn = "Get-${Language}-AdditionalValidationPackagesFromPackageSet"

# Expected to be set in eng/scripts/docs/Docs-Onboarding.ps1
$SetDocsPackageOnboarding = "Set-${Language}-DocsPackageOnboarding"
$GetDocsPackagesAlreadyOnboarded = "Get-${Language}-DocsPackagesAlreadyOnboarded"
$GetPackageIdentity = "Get-${Language}-PackageIdentity"
$GetPackageIdentityFromCsvMetadata = "Get-${Language}-PackageIdentityFromCsvMetadata"
