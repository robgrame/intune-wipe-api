#requires -Version 5.1
<#
.SYNOPSIS
    WinForms dialogs for the wipe-client result UI (success / failure /
    unknown state). Single source of truth used by Launch-Wipe.ps1.
.DESCRIPTION
    The default MessageBox is too terse for a destructive IT operation:
    when something goes wrong the user only sees "(401) Unauthorized" and
    has no way to tell the helpdesk what really happened. These dialogs
    surface:
      - A clear, business-friendly summary line.
      - The Correlation Id prominently (the helpdesk needs it to look the
        request up in App Insights).
      - A collapsible/scrollable "technical details" pane with the full
        server response, HTTP status, certificate used, device identifiers
        and timestamp.
      - A "Copy details" button so the user can paste everything into the
        helpdesk ticket in one click.

    PowerShell 5.1 reads .ps1 files as Windows-1252 unless they have a
    UTF-8 BOM. We build non-ASCII glyphs via [char] codes so the visible
    text stays correct regardless of how the file is saved.
#>

function _New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H,
          [System.Drawing.Font]$Font, [System.Drawing.Color]$Color)
    $l = New-Object System.Windows.Forms.Label
    $l.Text     = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size     = New-Object System.Drawing.Size($W, $H)
    if ($Font)  { $l.Font      = $Font }
    if ($Color) { $l.ForeColor = $Color }
    $l.AutoSize = $false
    return $l
}

function Format-WipeErrorDetails {
    <#
    .SYNOPSIS
        Render the rich error envelope written by Invoke-WipeFromTask.ps1
        into a multi-line technical block suitable for copy/paste into a
        helpdesk ticket.
    #>
    param([Parameter(Mandatory)] $Result)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('--- Dettagli tecnici ---')
    $lines.Add(('Timestamp     : {0}' -f $Result.ts))
    if ($Result.correlationId)       { $lines.Add(('CorrelationId : {0}' -f $Result.correlationId)) }
    if ($Result.serverCorrelationId -and $Result.serverCorrelationId -ne $Result.correlationId) {
        $lines.Add(('ServerCorrId  : {0}' -f $Result.serverCorrelationId))
    }
    if ($Result.kind)                { $lines.Add(('ErrorKind     : {0}' -f $Result.kind)) }
    if ($Result.httpStatusCode)      { $lines.Add(('HttpStatus    : {0} {1}' -f $Result.httpStatusCode, $Result.httpStatusReason)) }
    if ($Result.serverStatus)        { $lines.Add(('ServerStatus  : {0}' -f $Result.serverStatus)) }
    if ($Result.serverMessage)       { $lines.Add(('ServerMessage : {0}' -f $Result.serverMessage)) }
    if ($Result.clientMessage)       { $lines.Add(('ClientMessage : {0}' -f $Result.clientMessage)) }
    if ($Result.message -and $Result.message -ne $Result.serverMessage -and $Result.message -ne $Result.clientMessage) {
        $lines.Add(('Message       : {0}' -f $Result.message))
    }
    if ($Result.apiUrl)              { $lines.Add(('ApiUrl        : {0}' -f $Result.apiUrl)) }
    if ($Result.deviceName)          { $lines.Add(('Device        : {0}' -f $Result.deviceName)) }
    if ($Result.entraDeviceId)       { $lines.Add(('EntraDeviceId : {0}' -f $Result.entraDeviceId)) }
    if ($Result.intuneDeviceId)      { $lines.Add(('IntuneDevId   : {0}' -f $Result.intuneDeviceId)) }
    if ($Result.certSubject)         { $lines.Add(('CertSubject   : {0}' -f $Result.certSubject)) }
    if ($Result.certThumbprint)      { $lines.Add(('CertThumb     : {0}' -f $Result.certThumbprint)) }
    if ($Result.serverBodyRaw) {
        $lines.Add('--- Risposta del server ---')
        $lines.Add([string]$Result.serverBodyRaw)
    }
    return ($lines -join "`r`n")
}

function Show-WipeSuccessDialog {
    <#
    .SYNOPSIS
        Friendly confirmation that the API accepted the wipe request.
    #>
    param(
        [Parameter(Mandatory)] [string] $CorrelationId,
        [string] $DeviceName = $env:COMPUTERNAME
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $e_grave = [char]0x00E8
    $a_grave = [char]0x00E0

    $form              = New-Object System.Windows.Forms.Form
    $form.Text         = 'Reset richiesto'
    $form.Size         = New-Object System.Drawing.Size(560, 320)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox  = $false
    $form.MinimizeBox  = $false
    $form.TopMost      = $true
    $form.BackColor    = [System.Drawing.Color]::White

    $icon = New-Object System.Windows.Forms.PictureBox
    $icon.Image    = [System.Drawing.SystemIcons]::Information.ToBitmap()
    $icon.SizeMode = 'CenterImage'
    $icon.Location = New-Object System.Drawing.Point(20, 20)
    $icon.Size     = New-Object System.Drawing.Size(48, 48)
    $form.Controls.Add($icon)

    $title = _New-Label -Text "Richiesta di reset accettata" -X 85 -Y 20 -W 440 -H 30 `
        -Font (New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)) `
        -Color ([System.Drawing.Color]::FromArgb(0, 90, 158))
    $form.Controls.Add($title)

    $bodyText = (
        "Il dispositivo $DeviceName verr$($a_grave) reimpostato a breve.`r`n" +
        "Durante l'operazione il dispositivo non sar$($a_grave) utilizzabile per circa 90 minuti.`r`n`r`n" +
        "Comunica il seguente codice di correlazione all'IT helpdesk in caso di problemi:"
    )
    $body = _New-Label -Text $bodyText -X 85 -Y 55 -W 440 -H 90 `
        -Font (New-Object System.Drawing.Font('Segoe UI', 10))
    $form.Controls.Add($body)

    $corr = New-Object System.Windows.Forms.TextBox
    $corr.Text       = if ($CorrelationId) { $CorrelationId } else { 'n/d' }
    $corr.ReadOnly   = $true
    $corr.Location   = New-Object System.Drawing.Point(85, 150)
    $corr.Size       = New-Object System.Drawing.Size(380, 26)
    $corr.Font       = New-Object System.Drawing.Font('Consolas', 10)
    $corr.BackColor  = [System.Drawing.Color]::FromArgb(245, 245, 245)
    $form.Controls.Add($corr)

    $copyBtn = New-Object System.Windows.Forms.Button
    $copyBtn.Text     = 'Copia'
    $copyBtn.Location = New-Object System.Drawing.Point(470, 149)
    $copyBtn.Size     = New-Object System.Drawing.Size(60, 28)
    $copyBtn.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($corr.Text) }.GetNewClosure())
    $form.Controls.Add($copyBtn)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text         = 'OK'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Size         = New-Object System.Drawing.Size(110, 32)
    $ok.Location     = New-Object System.Drawing.Point(420, 230)
    $ok.Font         = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($ok)
    $form.AcceptButton = $ok

    [void] $form.ShowDialog()
    $form.Dispose()
}

function Show-WipeErrorDialog {
    <#
    .SYNOPSIS
        Detailed error dialog with collapsible technical details and a
        one-click "Copy details" button so the user can paste everything
        into a helpdesk ticket.
    .PARAMETER Result
        The parsed last-result.json object (see Invoke-WipeFromTask.ps1).
    #>
    param(
        [Parameter(Mandatory)] $Result,
        [string] $Title = 'Errore durante il reset del dispositivo'
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $a_grave = [char]0x00E0
    $e_grave = [char]0x00E8
    $o_grave = [char]0x00F2

    # Derive a friendly summary based on the server response when possible.
    $summary  = "Non $($e_grave) stato possibile completare la richiesta di reset."
    $advice   = "Riprova fra qualche minuto. Se l'errore persiste, contatta l'IT helpdesk fornendo il codice di correlazione qui sotto."
    $code     = $null
    if ($Result.httpStatusCode) {
        $code = ('HTTP {0}' -f $Result.httpStatusCode)
        if ($Result.httpStatusReason) { $code += (' {0}' -f $Result.httpStatusReason) }
    }
    if ($Result.serverMessage) {
        $summary = [string]$Result.serverMessage
    } elseif ($Result.message) {
        $summary = [string]$Result.message
    }

    $corrText = $null
    if ($Result.correlationId)            { $corrText = [string]$Result.correlationId }
    elseif ($Result.serverCorrelationId)  { $corrText = [string]$Result.serverCorrelationId }
    if (-not $corrText) { $corrText = 'n/d' }

    $details = Format-WipeErrorDetails -Result $Result

    $form              = New-Object System.Windows.Forms.Form
    $form.Text         = $Title
    $form.Size         = New-Object System.Drawing.Size(660, 380)
    $form.MinimumSize  = New-Object System.Drawing.Size(660, 380)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'Sizable'
    $form.MaximizeBox  = $true
    $form.MinimizeBox  = $false
    $form.TopMost      = $true
    $form.BackColor    = [System.Drawing.Color]::White

    $icon = New-Object System.Windows.Forms.PictureBox
    $icon.Image    = [System.Drawing.SystemIcons]::Error.ToBitmap()
    $icon.SizeMode = 'CenterImage'
    $icon.Location = New-Object System.Drawing.Point(20, 20)
    $icon.Size     = New-Object System.Drawing.Size(48, 48)
    $icon.Anchor   = 'Top, Left'
    $form.Controls.Add($icon)

    $title = _New-Label -Text "Reset non completato" -X 85 -Y 20 -W 530 -H 28 `
        -Font (New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)) `
        -Color ([System.Drawing.Color]::FromArgb(168, 0, 0))
    $title.Anchor = 'Top, Left, Right'
    $form.Controls.Add($title)

    $sumLines = @($summary)
    if ($code) { $sumLines = @(("$summary  ($code)")) }
    $sumLines += ''
    $sumLines += $advice
    $summaryLbl = _New-Label -Text ($sumLines -join "`r`n") -X 85 -Y 52 -W 540 -H 78 `
        -Font (New-Object System.Drawing.Font('Segoe UI', 10))
    $summaryLbl.Anchor = 'Top, Left, Right'
    $form.Controls.Add($summaryLbl)

    $corrLbl = _New-Label -Text 'Codice di correlazione:' -X 20 -Y 138 -W 180 -H 20 `
        -Font (New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold))
    $form.Controls.Add($corrLbl)

    $corr = New-Object System.Windows.Forms.TextBox
    $corr.Text       = $corrText
    $corr.ReadOnly   = $true
    $corr.Location   = New-Object System.Drawing.Point(200, 135)
    $corr.Size       = New-Object System.Drawing.Size(360, 26)
    $corr.Anchor     = 'Top, Left, Right'
    $corr.Font       = New-Object System.Drawing.Font('Consolas', 10)
    $corr.BackColor  = [System.Drawing.Color]::FromArgb(250, 245, 230)
    $form.Controls.Add($corr)

    $detailsBox = New-Object System.Windows.Forms.TextBox
    $detailsBox.Multiline   = $true
    $detailsBox.ReadOnly    = $true
    $detailsBox.ScrollBars  = 'Vertical'
    $detailsBox.WordWrap    = $true
    $detailsBox.Text        = $details
    $detailsBox.Location    = New-Object System.Drawing.Point(20, 170)
    $detailsBox.Size        = New-Object System.Drawing.Size(605, 130)
    $detailsBox.Anchor      = 'Top, Left, Right, Bottom'
    $detailsBox.Font        = New-Object System.Drawing.Font('Consolas', 9)
    $detailsBox.BackColor   = [System.Drawing.Color]::FromArgb(248, 248, 248)
    $detailsBox.Visible     = $false
    $form.Controls.Add($detailsBox)

    $toggle = New-Object System.Windows.Forms.Button
    $toggle.Text     = 'Mostra dettagli tecnici'
    $toggle.Location = New-Object System.Drawing.Point(20, 310)
    $toggle.Size     = New-Object System.Drawing.Size(190, 28)
    $toggle.Anchor   = 'Bottom, Left'
    $toggle.Add_Click({
        if ($detailsBox.Visible) {
            $detailsBox.Visible = $false
            $toggle.Text = 'Mostra dettagli tecnici'
        } else {
            $detailsBox.Visible = $true
            $toggle.Text = 'Nascondi dettagli tecnici'
        }
    }.GetNewClosure())
    $form.Controls.Add($toggle)

    $copyBtn = New-Object System.Windows.Forms.Button
    $copyBtn.Text     = 'Copia dettagli'
    $copyBtn.Location = New-Object System.Drawing.Point(220, 310)
    $copyBtn.Size     = New-Object System.Drawing.Size(130, 28)
    $copyBtn.Anchor   = 'Bottom, Left'
    $copyBtn.Add_Click({
        try {
            [System.Windows.Forms.Clipboard]::SetText($details)
            $copyBtn.Text = 'Copiato!'
        } catch { }
    }.GetNewClosure())
    $form.Controls.Add($copyBtn)

    $close = New-Object System.Windows.Forms.Button
    $close.Text         = 'Chiudi'
    $close.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $close.Size         = New-Object System.Drawing.Size(110, 32)
    $close.Location     = New-Object System.Drawing.Point(515, 308)
    $close.Anchor       = 'Bottom, Right'
    $close.Font         = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($close)
    $form.AcceptButton  = $close
    $form.CancelButton  = $close

    [void] $form.ShowDialog()
    $form.Dispose()
}

function Show-WipeUnknownDialog {
    <#
    .SYNOPSIS
        Friendly "we don't know yet" dialog used when the SYSTEM task did
        not finish in time or did not write a result file.
    .PARAMETER ReasonHint
        Why we are showing this dialog. Tailors the body text so the user
        gets actionable guidance instead of a generic message:
          - StillRunning : the SYSTEM task is still working past the
                           launcher's 2-minute observation window.
          - BadJson      : the result file exists but cannot be parsed.
          - NoResultFile : the task finished but did not write a result.
        Defaults to NoResultFile for backwards compatibility.
    #>
    param(
        [string] $LogPath = (Join-Path $env:ProgramData 'IntuneWipeClient\Logs'),
        [ValidateSet('StillRunning','BadJson','NoResultFile')]
        [string] $ReasonHint = 'NoResultFile'
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $e_grave = [char]0x00E8
    $a_grave = [char]0x00E0

    switch ($ReasonHint) {
        'StillRunning' {
            $titleText = "Operazione ancora in corso"
            $bodyText  = (
                "La richiesta di reset $($e_grave) stata avviata ma il task locale non $($e_grave) ancora terminato la propria attivit$($a_grave) di notifica.`r`n`r`n" +
                "Lo wipe potrebbe gi$($a_grave) essere stato accettato lato Intune. Riprova fra 1-2 minuti per visualizzare l'esito finale.`r`n`r`n" +
                "Se il problema persiste, contatta l'IT helpdesk e fornisci il contenuto della cartella di log:`r`n$LogPath"
            )
            $headerColor = [System.Drawing.Color]::FromArgb(0, 99, 177)
        }
        'BadJson' {
            $titleText = "Risultato non leggibile"
            $bodyText  = (
                "Il task SYSTEM ha scritto un file di risultato non valido.`r`n`r`n" +
                "Contatta l'IT helpdesk e fornisci il contenuto della cartella di log e del file last-result.json:`r`n$LogPath"
            )
            $headerColor = [System.Drawing.Color]::FromArgb(176, 122, 0)
        }
        default {
            $titleText = "Stato non disponibile (v1.0.17)"
            $bodyText  = (
                "La richiesta $($e_grave) stata avviata ma il task SYSTEM $($e_grave) terminato senza scrivere un risultato.`r`n`r`n" +
                "Questo $($e_grave) un caso anomalo (non dovrebbe pi$($e_grave) accadere da v1.0.16). Probabili cause: AppLocker/WDAC blocca powershell.exe come SYSTEM, oppure il file 'C:\Program Files\IntuneWipeClient\Invoke-WipeFromTask.ps1' $($e_grave) stato manomesso.`r`n`r`n" +
                "Contatta l'IT helpdesk e fornisci il contenuto della cartella di log:`r`n$LogPath"
            )
            $headerColor = [System.Drawing.Color]::FromArgb(176, 122, 0)
        }
    }

    $form              = New-Object System.Windows.Forms.Form
    $form.Text         = 'Stato non disponibile'
    $form.Size         = New-Object System.Drawing.Size(560, 280)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox  = $false
    $form.MinimizeBox  = $false
    $form.TopMost      = $true
    $form.BackColor    = [System.Drawing.Color]::White

    $icon = New-Object System.Windows.Forms.PictureBox
    $icon.Image    = if ($ReasonHint -eq 'StillRunning') { [System.Drawing.SystemIcons]::Information.ToBitmap() } else { [System.Drawing.SystemIcons]::Warning.ToBitmap() }
    $icon.SizeMode = 'CenterImage'
    $icon.Location = New-Object System.Drawing.Point(20, 20)
    $icon.Size     = New-Object System.Drawing.Size(48, 48)
    $form.Controls.Add($icon)

    $title = _New-Label -Text $titleText -X 85 -Y 20 -W 440 -H 30 `
        -Font (New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)) `
        -Color $headerColor
    $form.Controls.Add($title)

    $body = _New-Label -Text $bodyText -X 85 -Y 55 -W 440 -H 140 `
        -Font (New-Object System.Drawing.Font('Segoe UI', 10))
    $form.Controls.Add($body)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text         = 'OK'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Size         = New-Object System.Drawing.Size(110, 32)
    $ok.Location     = New-Object System.Drawing.Point(420, 200)
    $ok.Font         = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($ok)
    $form.AcceptButton = $ok

    [void] $form.ShowDialog()
    $form.Dispose()
}
