[CmdletBinding()]
param([ValidateSet('Prepare', 'Validate')][string]$Mode = 'Prepare', [Parameter(Mandatory)][string]$OfficialSourceRoot, [string]$OutputRoot)
$ErrorActionPreference = 'Stop'
$SourceCommit = '8971c3fc6601fdfd30a9a31b35cffdb1ab67163b'
$BaseDigest = 'sha256:d03570ebcaf189df85e5b64497a40861ff3ab320e7ee1c90ec4c5b082a4c8b72'
if ($Mode -eq 'Validate') {
    foreach ($Item in @(@{Module = 'CIPPCore'; Function = 'Get-CIPPMailboxPermissionEvidence'}, @{Module = 'CIPPHTTP'; Function = 'Invoke-ListMailboxPermissionEvidence'})) {
        $ModuleRoot = Join-Path $OfficialSourceRoot $Item.Module
        $Tokens = $null; $Errors = $null
        $Ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $ModuleRoot ($Item.Module + '.psm1')), [ref]$Tokens, [ref]$Errors)
        if ($Errors.Count) { throw 'Compiled module parse failed' }
        $Name = $Item.Function
        $Functions = @($Ast.FindAll({param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq $Name}, $true))
        if ($Functions.Count -ne 1) { throw 'Compiled function missing or duplicated' }
        $Manifest = Import-PowerShellDataFile (Join-Path $ModuleRoot ($Item.Module + '.psd1'))
        if ($Manifest.RootModule -cne ($Item.Module + '.psm1') -or (@($Manifest.FunctionsToExport) -notcontains $Name -and @($Manifest.FunctionsToExport) -notcontains '*')) { throw 'Compiled export/root invalid' }
        if ($Item.Module -eq 'CIPPHTTP' -and $Functions[0].Extent.Text -notmatch '(?s)\.ROLE\s+Exchange\.Mailbox\.Read\s+\.DESCRIPTION') { throw 'HTTP role metadata missing' }
        if (Test-Path (Join-Path $ModuleRoot 'Public')) { throw 'Uncompiled Public directory remains' }
    }
    Write-Output 'Compiled module parser/export/role checks passed; runtime loader acceptance remains required.'
    return
}
if (-not $OutputRoot) { throw 'An empty owned output directory is required' }
$Source = (Resolve-Path -LiteralPath $OfficialSourceRoot).Path
$Output = [IO.Path]::GetFullPath($OutputRoot)
if ($Output.StartsWith($Source.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $Output -eq $Source) { throw 'Output must be outside the upstream source tree' }
if (Test-Path -LiteralPath $Output) { if (@(Get-ChildItem -LiteralPath $Output -Force).Count) { throw 'Output directory must be empty' } }
if ((& git -C $Source rev-parse HEAD).Trim() -cne $SourceCommit -or $LASTEXITCODE -ne 0) { throw 'Wrong official source commit' }
$SourceStatus = & git -C $Source status --porcelain
if ($LASTEXITCODE -ne 0 -or $SourceStatus) { throw 'Official source must be clean' }
$Paths = @('build/Metadata/1.5.7', 'build/Configuration/1.6.0', 'build/ModuleBuilder/3.1.8', 'build/tools/build-single-module.ps1', 'backend/Modules/CIPPCore', 'backend/Modules/CIPPHTTP')
New-Item -ItemType Directory -Path $Output -Force | Out-Null
foreach ($Relative in $Paths) {
    $Target = Join-Path $Output $Relative
    New-Item -ItemType Directory -Path (Split-Path $Target -Parent) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Source $Relative) -Destination $Target -Recurse
}
$Bindings = @(
    @{File = 'Get-CIPPMailboxPermissionEvidence.ps1'; Target = 'backend/Modules/CIPPCore/Public/Get-CIPPMailboxPermissionEvidence.ps1'},
    @{File = 'Invoke-ListMailboxPermissionEvidence.ps1'; Target = 'backend/Modules/CIPPHTTP/Public/Entrypoints/HTTP Functions/Email-Exchange/Administration/Invoke-ListMailboxPermissionEvidence.ps1'}
)
foreach ($Binding in $Bindings) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('provider/' + $Binding.File)) -Destination (Join-Path $Output $Binding.Target) }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Dockerfile.overlay') -Destination (Join-Path $Output 'Dockerfile')
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $Output 'prepare-context.ps1')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'LICENSE.upstream.md') -Destination (Join-Path $Output 'LICENSE.upstream.md')
$Spec = Get-Content -LiteralPath (Join-Path $Source 'backend/Config/openapi.json') -Raw | ConvertFrom-Json -AsHashtable
$Operation = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'openapi-operation.json') -Raw | ConvertFrom-Json -AsHashtable
$Spec.paths['/api/ListMailboxPermissionEvidence'] = $Operation
$Config = Join-Path $Output 'runtime/Config'; $Frontend = Join-Path $Output 'runtime/Frontend'
New-Item -ItemType Directory -Path $Config, $Frontend -Force | Out-Null
$Utf8 = [Text.UTF8Encoding]::new($false)
$SpecPath = Join-Path $Config 'openapi.json'
[IO.File]::WriteAllText($SpecPath, ($Spec | ConvertTo-Json -Depth 100 -Compress), $Utf8)
$Profile = [ordered]@{ contract = 'cipp-mailbox-evidence:v1'; sourceCommit = $SourceCommit; baseImageDigest = $BaseDigest
    handlerSha256 = (Get-FileHash -Algorithm SHA256 (Join-Path $PSScriptRoot 'provider/Invoke-ListMailboxPermissionEvidence.ps1')).Hash.ToLowerInvariant()
    helperSha256 = (Get-FileHash -Algorithm SHA256 (Join-Path $PSScriptRoot 'provider/Get-CIPPMailboxPermissionEvidence.ps1')).Hash.ToLowerInvariant()
    openapiSha256 = (Get-FileHash -Algorithm SHA256 $SpecPath).Hash.ToLowerInvariant() }
$Canonical = $Profile | ConvertTo-Json -Compress
$Profile.readerProfileId = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Utf8.GetBytes($Canonical))).ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $Config 'mailbox-evidence-profile.json'), ($Profile | ConvertTo-Json -Compress), $Utf8)
Copy-Item -LiteralPath $SpecPath -Destination (Join-Path $Frontend 'openapi.json')
foreach ($Dir in @($Config, $Frontend)) {
    $Bytes = [IO.File]::ReadAllBytes((Join-Path $Dir 'openapi.json'))
    foreach ($Kind in @('gzip', 'brotli')) {
        $Extension = if ($Kind -eq 'gzip') { '.gz' } else { '.br' }
        $Stream = [IO.File]::Create((Join-Path $Dir ('openapi.json' + $Extension)))
        try {
            $Compressor = if ($Kind -eq 'gzip') { [IO.Compression.GZipStream]::new($Stream, [IO.Compression.CompressionLevel]::SmallestSize) } else { [IO.Compression.BrotliStream]::new($Stream, [IO.Compression.CompressionLevel]::SmallestSize) }
            try { $Compressor.Write($Bytes, 0, $Bytes.Length) } finally { $Compressor.Dispose() }
        } finally { $Stream.Dispose() }
    }
}
$Inventory = @(Get-ChildItem -LiteralPath $Output -Recurse -File | ForEach-Object { [ordered]@{ path = [IO.Path]::GetRelativePath($Output, $_.FullName).Replace('\', '/'); sha256 = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant() } } | Sort-Object path)
[IO.File]::WriteAllText((Join-Path $Output 'context-manifest.json'), ([ordered]@{ sourceCommit = $SourceCommit; baseImageDigest = $BaseDigest; buildImageDigest = 'sha256:6ba9644da07bb5b560a402acec9ca38711a0762969f1b61da261df5c9f6f85da'; readerProfileId = $Profile.readerProfileId; files = $Inventory } | ConvertTo-Json -Depth 8), $Utf8)
Write-Output "Prepared minimal context; readerProfileId=$($Profile.readerProfileId). No image build/publication/deployment performed."
