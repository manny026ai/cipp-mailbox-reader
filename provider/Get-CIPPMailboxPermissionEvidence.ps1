function Get-CIPPMailboxPermissionEvidence {
    <# .FUNCTIONALITY Internal #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$Mailbox, [Parameter(Mandatory)][string]$SubjectId)
    # CIPP-owned EXO transport/custody. No caller-selected command, URL, auth mode or report path.
    $Started = [DateTimeOffset]::UtcNow
    $Deadline = $Started.AddSeconds(8)
    $GuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    if ($TenantId -notmatch $GuidPattern -or $SubjectId -notmatch $GuidPattern -or $TenantId -eq [guid]::Empty.ToString() -or $SubjectId -eq [guid]::Empty.ToString()) { throw 'invalid_scope' }
    if ($Mailbox -notmatch $GuidPattern -and $Mailbox -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._+-]{0,63}@[a-zA-Z0-9.-]{1,190}\.[a-zA-Z]{2,63}$') { throw 'invalid_scope' }
    if (-not (Get-AuthorisedRequest -TenantID $TenantId)) { throw 'reader_denied' }
    # Build-generated, fixed runtime path; source hashes are computed after source/schema exist.
    $ProfilePath = Join-Path $env:CIPPRootPath 'Config/mailbox-evidence-profile.json'
    try {
        if ((Get-Item -LiteralPath $ProfilePath -ErrorAction Stop).Length -gt 4096) { throw 'profile_unavailable' }
        $ReaderProfile = Get-Content -LiteralPath $ProfilePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch { throw 'profile_unavailable' }
    if ($ReaderProfile.contract -cne 'cipp-mailbox-evidence:v1' -or $ReaderProfile.readerProfileId -cnotmatch '^[a-f0-9]{64}$') { throw 'profile_unavailable' }
    $Tenants = @(Get-Tenants -IncludeErrors -TenantFilter $TenantId)
    if ($Tenants.Count -ne 1 -or "$($Tenants[0].customerId)" -ine $TenantId) { throw 'tenant_unverified' }
    $Token = Get-GraphToken -Tenantid $TenantId -scope 'https://outlook.office365.com/.default'
    if (-not $Token.Authorization) { throw 'reader_denied' }
    $Commands = [System.Collections.Generic.List[object]]::new()
    function Read-EvidenceCommand {
        param([ValidateSet('Get-Mailbox', 'Get-Recipient', 'Get-RecipientPermission')][string]$Name, [string]$Identity, [int]$Cap, [string]$Select)
        $Remaining = [Math]::Floor(($Deadline - [DateTimeOffset]::UtcNow).TotalSeconds)
        if ($Remaining -lt 1) { throw 'reader_timeout' }
        $Params = @{ Identity = $Identity; ResultSize = ($Cap + 1) }
        $Body = @{ CmdletInput = @{ CmdletName = $Name; Parameters = $Params } } | ConvertTo-Json -Depth 8 -Compress
        $Url = "https://outlook.office365.com/adminapi/beta/$TenantId/InvokeCommand"
        if ($Select) { $Url += '?$select=' + [uri]::EscapeDataString($Select) }
        $Status = 0; $ResponseHeaders = @{}
        $Headers = @{ Authorization = $Token.Authorization; Prefer = 'odata.maxpagesize=101'; 'X-AnchorMailbox' = "APP:SystemMailbox{bb558c35-97f1-4cb9-8ff7-d53741dc928c}@$TenantId" }
        try {
            $Response = Invoke-CIPPRestMethod -Uri $Url -Method POST -Body $Body -Headers $Headers -ContentType 'application/json; charset=utf-8' -TimeoutSec ([Math]::Min(3, $Remaining)) -MaximumRedirection 0 -StatusCodeVariable Status -ResponseHeadersVariable ResponseHeaders -ErrorAction Stop
        } catch {
            $NativeFailure = $_.Exception.GetBaseException()
            if ($NativeFailure -is [TimeoutException] -or $NativeFailure -is [OperationCanceledException]) { throw 'reader_timeout' }
            if ($NativeFailure.StatusCode -in @(401, 403)) { throw 'reader_denied' }
            if ($NativeFailure.StatusCode -eq 429) { throw 'reader_rate_limited' }
            throw 'evidence_unavailable'
        }
        if ($Status -in @(401, 403)) { throw 'reader_denied' }
        if ($Status -eq 429) { throw 'reader_rate_limited' }
        if ([DateTimeOffset]::UtcNow -ge $Deadline) { throw 'reader_timeout' }
        if ($Status -ne 200) { throw 'reader_incomplete' }
        if ($null -eq $Response -or $Response -is [string] -or $Response -is [array]) { throw 'reader_incomplete' }
        if ($Response.'@odata.nextLink') { throw 'reader_pagination' }
        if ($Response.error -or $Response.'@adminapi.warnings' -or $Response.Metadata -or $Response.Results) { throw 'reader_incomplete' }
        if ($Response.value -isnot [array]) { throw 'reader_incomplete' }
        $Rows = @($Response.value)
        if ($Rows.Count -gt $Cap) { throw 'reader_limit' }
        # Buffer size rejection is secondary to native ResultSize+1 and row caps. It is not a streaming memory bound.
        if ([Text.Encoding]::UTF8.GetByteCount(($Response | ConvertTo-Json -Depth 12 -Compress)) -gt 262144) { throw 'reader_limit' }
        $Commands.Add([ordered]@{ name = $Name; status = 'complete'; httpStatus = 200; rowCount = $Rows.Count; pageCount = 1 })
        return ,$Rows
    }
    function Test-EvidenceTargetReference {
        param([object]$Value)
        return ($Value -is [string] -and $Value.Length -gt 0 -and $Value.Length -le 1024 -and $Value -ceq $Value.Trim() -and $Value -notmatch '[\x00-\x1f\x7f-\x9f*?\[\]]')
    }
    function Get-EvidenceMailboxLocators {
        param([object]$Row)
        $Locators = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($Value in @($Row.Name, $Row.Alias, $Row.PrimarySmtpAddress)) {
            if (Test-EvidenceTargetReference $Value) { $null = $Locators.Add($Value) }
        }
        return ,$Locators
    }
    try {
        # Name/Alias stay internal: lookup locators are not immutable identity proof or response fields.
        $MailboxSelect = 'ExternalDirectoryObjectId,ExchangeGuid,Guid,DistinguishedName,PrimarySmtpAddress,RecipientTypeDetails,Name,Alias'
        $Mailboxes = Read-EvidenceCommand -Name 'Get-Mailbox' -Identity $Mailbox -Cap 1 -Select $MailboxSelect
        $Subjects = Read-EvidenceCommand -Name 'Get-Recipient' -Identity $SubjectId -Cap 1 -Select 'ExternalDirectoryObjectId,Guid,Sid,RecipientTypeDetails,PrimarySmtpAddress'
        if ($Mailboxes.Count -ne 1 -or $Subjects.Count -ne 1) { throw 'identity_unverified' }
        $M = $Mailboxes[0]; $S = $Subjects[0]
        if ("$($M.ExternalDirectoryObjectId)" -notmatch $GuidPattern -or "$($M.ExchangeGuid)" -notmatch $GuidPattern -or "$($M.Guid)" -notmatch $GuidPattern -or "$($M.RecipientTypeDetails)" -cne 'SharedMailbox') { throw 'identity_unverified' }
        if (@("$($M.ExternalDirectoryObjectId)", "$($M.ExchangeGuid)", "$($M.Guid)") -contains [guid]::Empty.ToString()) { throw 'identity_unverified' }
        if ("$($S.ExternalDirectoryObjectId)" -ine $SubjectId -or "$($S.RecipientTypeDetails)" -notin @('UserMailbox', 'MailUser')) { throw 'identity_unverified' }
        if ($Mailbox -match $GuidPattern) {
            if ("$($M.ExchangeGuid)" -ine $Mailbox) { throw 'identity_unverified' }
        } elseif ("$($M.PrimarySmtpAddress)" -ine $Mailbox) { throw 'identity_unverified' }
        $Witness = [ordered]@{ objectId = "$($M.ExternalDirectoryObjectId)".ToLowerInvariant(); exchangeGuid = "$($M.ExchangeGuid)".ToLowerInvariant(); recipientGuid = "$($M.Guid)".ToLowerInvariant(); distinguishedName = if ("$($M.DistinguishedName)" -match '^CN=.{1,1020}$') { "$($M.DistinguishedName)" } else { $null }; primarySmtpAddress = "$($M.PrimarySmtpAddress)".ToLowerInvariant(); type = "$($M.RecipientTypeDetails)" }
        # RecipientPermission Identity is a recipient GUID, not the mailbox-store ExchangeGuid.
        $Aces = Read-EvidenceCommand -Name 'Get-RecipientPermission' -Identity $Witness.recipientGuid -Cap 100 -Select ''
        $InitialLocators = Get-EvidenceMailboxLocators $M
        $UnresolvedTargets = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $Entries = @(foreach ($Ace in $Aces) {
            # Never coerce an unproven JSON object/array into an Exchange identity string.
            $NativeTarget = $Ace.Identity
            if (-not (Test-EvidenceTargetReference $NativeTarget)) { throw 'target_unverified' }
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals($NativeTarget, $Witness.recipientGuid) -and (-not $Witness.distinguishedName -or -not [StringComparer]::OrdinalIgnoreCase.Equals($NativeTarget, $Witness.distinguishedName))) {
                if (-not $InitialLocators.Contains($NativeTarget)) { throw 'target_unverified' }
                $null = $UnresolvedTargets.Add($NativeTarget)
                if ($UnresolvedTargets.Count -gt 1) { throw 'target_unverified' }
            }
            $Trustee = if ($null -ne $Ace.Trustee) { "$($Ace.Trustee)" } else { $null }
            if ($Trustee -and $Trustee.Length -gt 256) { throw 'reader_limit' }
            $Rights = @($Ace.AccessRights | ForEach-Object { "$_" })
            if ($Rights.Count -gt 8 -or @($Rights | Where-Object { $_.Length -gt 64 }).Count) { throw 'reader_limit' }
            [ordered]@{
                targetIdentity = $null # Filled only after the final native immutable witness matches.
                trustee = $Trustee
                accessRights = $Rights
                accessControlType = if ($null -ne $Ace.AccessControlType) { "$($Ace.AccessControlType)" } else { $null }
                isInherited = if ($Ace.IsInherited -is [bool]) { $Ace.IsInherited } else { $null }
                inheritanceType = if ($null -ne $Ace.InheritanceType) { "$($Ace.InheritanceType)" } else { $null }
            }
        })
        # Reuse read4 for the single corroborated locator. No extra command, query-only proof or retry.
        $FinalIdentity = if ($UnresolvedTargets.Count -eq 1) { @($UnresolvedTargets)[0] } else { $Witness.recipientGuid }
        $FinalMailbox = Read-EvidenceCommand -Name 'Get-Mailbox' -Identity $FinalIdentity -Cap 1 -Select $MailboxSelect
        if ($FinalMailbox.Count -ne 1 -or "$($FinalMailbox[0].ExternalDirectoryObjectId)" -ine $Witness.objectId -or "$($FinalMailbox[0].Guid)" -ine $Witness.recipientGuid -or "$($FinalMailbox[0].ExchangeGuid)" -ine $Witness.exchangeGuid -or "$($FinalMailbox[0].PrimarySmtpAddress)" -ine $Witness.primarySmtpAddress -or "$($FinalMailbox[0].RecipientTypeDetails)" -cne $Witness.type -or -not [StringComparer]::OrdinalIgnoreCase.Equals($FinalMailbox[0].DistinguishedName, $Witness.distinguishedName)) { throw 'target_changed' }
        # Nonexistent Identity may return all objects. Matching the initial/final native locator AND
        # all immutable witness fields prevents accepting that fallthrough, even for a one-row tenant.
        if ($UnresolvedTargets.Count -eq 1 -and -not (Get-EvidenceMailboxLocators $FinalMailbox[0]).Contains($FinalIdentity)) { throw 'target_changed' }
        foreach ($Entry in $Entries) { $Entry.targetIdentity = $Witness.recipientGuid }
        if ([DateTimeOffset]::UtcNow -ge $Deadline) { throw 'reader_timeout' }
        $Sid = if ("$($S.Sid)".Length -le 184 -and "$($S.Sid)" -match '^S-1-\d+(?:-\d+)+$') { "$($S.Sid)" } else { $null }
        $RecipientGuid = if ("$($S.Guid)" -match $GuidPattern -and "$($S.Guid)" -ne [guid]::Empty.ToString()) { "$($S.Guid)".ToLowerInvariant() } else { $null }
        $CanonicalAddress = if ("$($S.PrimarySmtpAddress)".Length -le 254 -and "$($S.PrimarySmtpAddress)" -match '^[a-zA-Z0-9][a-zA-Z0-9._+-]{0,63}@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,63}$') { "$($S.PrimarySmtpAddress)".ToLowerInvariant() } else { $null }
        return [ordered]@{
            contract = 'cipp-mailbox-evidence:v1'; profileId = $ReaderProfile.readerProfileId; source = 'live_exchange'; tenantId = $TenantId.ToLowerInvariant()
            collectedAt = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'); complete = $true
            mailbox = $Witness
            subject = [ordered]@{ objectId = "$($S.ExternalDirectoryObjectId)".ToLowerInvariant(); recipientGuid = $RecipientGuid; sid = $Sid; primarySmtpAddress = $CanonicalAddress }
            commands = @($Commands); entries = @($Entries)
        }
    } finally { $Token = $null }
}
