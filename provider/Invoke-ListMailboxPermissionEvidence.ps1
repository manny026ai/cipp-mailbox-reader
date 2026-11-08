function Invoke-ListMailboxPermissionEvidence {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Exchange.Mailbox.Read
    .DESCRIPTION
        Reads exact shared-mailbox SendAs evidence with native ACE fields and complete-success witnesses. No report cache or effective-access/approval decision.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)
    $QueryNames = if ($Request.Query -is [System.Collections.IDictionary]) { @($Request.Query.Keys) } else { @($Request.Query.PSObject.Properties.Name) }
    # Optional _fresh: a caller-chosen value that only varies the URL so the host response cache never answers a read.
    $HasFresh = $QueryNames -ccontains '_fresh'
    $FreshValid = -not $HasFresh -or ([string]$Request.Query._fresh -cmatch '^[0-9a-f]{24}$')
    if ($Request.Method -ine 'GET' -or $Request.Body -or @($QueryNames | Where-Object { $_ -cnotin @('tenantFilter', 'mailbox', 'subjectId', '_fresh') }).Count -or
        @(@('tenantFilter', 'mailbox', 'subjectId') | Where-Object { $_ -cnotin $QueryNames }).Count -or $QueryNames.Count -ne $(if ($HasFresh) { 4 } else { 3 }) -or -not $FreshValid) {
        return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = @{ code = 'invalid_scope' } })
    }
    try {
        $Evidence = Get-CIPPMailboxPermissionEvidence -TenantId $Request.Query.tenantFilter -Mailbox $Request.Query.mailbox -SubjectId $Request.Query.subjectId -ErrorAction Stop
        return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = $Evidence; Headers = @{ 'Cache-Control' = 'no-store' } })
    } catch {
        # No native payload, identities, tokens or diagnostic exception text in errors/logs.
        $Known = @('invalid_scope', 'reader_denied', 'reader_rate_limited', 'tenant_unverified', 'profile_unavailable', 'reader_timeout', 'reader_incomplete', 'reader_pagination', 'reader_limit', 'identity_unverified', 'target_unverified', 'target_changed')
        $Code = if ($_.Exception.Message -cin $Known) { $_.Exception.Message } else { 'evidence_unavailable' }
        return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::UnprocessableEntity; Body = @{ code = $Code }; Headers = @{ 'Cache-Control' = 'no-store' } })
    }
}
