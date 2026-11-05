<#
.SYNOPSIS
    Installs the desktop tool on Windows: one folder, nothing to administer.

.DESCRIPTION
    The Windows form of `install-desktop.sh`, and the one line that installs it:

        powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/d-led/confluence_phx_mirror/main/install-desktop.ps1 | iex"

    What it downloads is the artifact of the last successful `desktop-release`
    run of a branch, through `nightly.link` — there is no release to wait for.
    It lands in `%LOCALAPPDATA%\Programs\Confluence Export`, with a Start Menu
    entry beside it, and the tool keeps its catalogue in
    `%LOCALAPPDATA%\confluence-export`. Run it again and it opens what is
    already there; `-Update` takes the newest build first.

        -Update                download the newest build even if one is here

        CONFLUENCE_EXPORT_REPO      owner/repo to download from (default: d-led/confluence_phx_mirror)
        CONFLUENCE_EXPORT_BRANCH    which branch's build to take (default: main)
        CONFLUENCE_EXPORT_WORKFLOW  the workflow that builds it (default: desktop-release)
        CONFLUENCE_EXPORT_DIR       where it lands (default: %LOCALAPPDATA%\Programs\Confluence Export)
        CONFLUENCE_EXPORT_BASE_URL  a folder or address holding
                                    confluence-export-windows.zip itself, which
                                    skips nightly.link — how this is tested
        CONFLUENCE_EXPORT_UPDATE    the one-liner's form of -Update: `1`, `true`
                                    or `yes`

    Two things it does not do. It does not retry for ever: the download gets a
    deadline and three attempts, so a build that is not there yet says so and
    stops. And it reads nothing from standard input — `irm … | iex` runs this
    from the pipeline, so a prompt that waits for input would wait for ever.

    The build is not signed, so Windows shows a SmartScreen "unrecognised app"
    prompt the first time; *More info* then *Run anyway* is the whole of it.
    The download marker is cleared here, on the copy this script just made,
    because a person who asked for this install has asked for this app to run.
#>

param(
    [switch]$Update
)

# `irm … | iex` cannot pass a switch: the one-liner's form of -Update is the
# environment, `$env:CONFLUENCE_EXPORT_UPDATE = 1`.
if ($env:CONFLUENCE_EXPORT_UPDATE -in @('1', 'true', 'yes')) { $Update = $true }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'The desktop tool installs on Windows with this script, and this is not Windows.'
    Write-Host 'macOS and Linux have install-desktop.sh:' `
        -NoNewline
    Write-Host ' https://raw.githubusercontent.com/d-led/confluence_phx_mirror/main/install-desktop.sh'
    exit 1
}

$repo = if ($env:CONFLUENCE_EXPORT_REPO) { $env:CONFLUENCE_EXPORT_REPO } else { 'd-led/confluence_phx_mirror' }
$branch = if ($env:CONFLUENCE_EXPORT_BRANCH) { $env:CONFLUENCE_EXPORT_BRANCH } else { 'main' }
$workflow = if ($env:CONFLUENCE_EXPORT_WORKFLOW) { $env:CONFLUENCE_EXPORT_WORKFLOW } else { 'desktop-release' }
$artifact = 'confluence-export-windows'
$app = 'Confluence Export'

$dir = if ($env:CONFLUENCE_EXPORT_DIR) {
    $env:CONFLUENCE_EXPORT_DIR
}
else {
    Join-Path $env:LOCALAPPDATA "Programs\$app"
}

$instance = Join-Path $dir $artifact
$exe = Join-Path $instance 'confluence-export.exe'

if (-not $Update -and (Test-Path $exe)) {
    Write-Host "$exe is already here."
}
else {
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("confluence-export-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    try {
        $zip = Join-Path $work "$artifact.zip"
        $folder = $env:CONFLUENCE_EXPORT_BASE_URL

        if ($folder) {
            # A folder on this machine is how this is tried without a network
            # round trip, which is what the shell twin does too.
            if ($folder -match '^(https?|file)://') {
                $source = "$folder/$artifact.zip"
            }
            else {
                $source = Join-Path $folder "$artifact.zip"
            }

            Write-Host "Taking $source ..."
            if ($source -match '^(https?|file)://') {
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $source -OutFile $zip
            }
            else {
                Copy-Item -LiteralPath $source -Destination $zip
            }
        }
        else {
            $source = "https://nightly.link/$repo/workflows/$workflow/$branch/$artifact.zip"
            Write-Host "Downloading the newest $branch build of $workflow ..."

            # The progress bar is why a download of hundreds of megabytes takes
            # minutes in Windows PowerShell: it redraws the console per block.
            $ProgressPreference = 'SilentlyContinue'

            try {
                Invoke-WebRequest -Uri $source -OutFile $zip
            }
            catch {
                # A sentence, not a stack: an artifact that is not there yet is
                # the expected answer while a platform's job is red.
                Write-Host "Nothing came from $source — $($_.Exception.Message)"
                Write-Host 'Nothing was installed. Whether that build exists is on the workflow page:'
                Write-Host "  https://github.com/$repo/actions/workflows/$workflow.yml"
                exit 1
            }
        }

        # `tar`, because Windows ships bsdtar and it reads a zip: the artifact is
        # a folder zipped by `upload-artifact`, inside the zip `nightly.link`
        # makes of it. Said out loud, because unpacking takes a moment.
        Write-Host 'Unpacking the download ...'
        tar -x -f $zip -C $work
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'The download could not be unpacked. Nothing was installed.'
            exit 1
        }

        # Found rather than assumed: what makes it the tool is the window, and
        # the folder's name is whatever the packaging called it.
        $found = Get-ChildItem -Path $work -Recurse -Filter 'confluence-export.exe' -File |
            Select-Object -First 1
        if ($null -eq $found) {
            Write-Host 'The download did not contain the application. Nothing was installed.'
            exit 1
        }

        # Replaced, not merged: two builds of the same folder leave files from
        # the older one behind, and nothing could explain them later.
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Remove-Item -Recurse -Force $instance -ErrorAction SilentlyContinue
        Move-Item -Path $found.Directory.FullName -Destination $instance

        # A file that arrived through `Invoke-WebRequest` carries a zone
        # identifier, and Windows then asks before running it. Asked once, and
        # only when one is there: walking fifteen thousand files to delete a
        # marker none of them has is a minute spent on nothing. Whether this
        # PowerShell can read an alternate data stream at all is asked as a fact
        # rather than found by failing, because this runs under `iex`, where the
        # first unhandled error is the end of the install.
        $readsStreams = (Get-Command Get-Item).Parameters.ContainsKey('Stream')
        if ($readsStreams -and
            $null -ne (Get-Item -LiteralPath $exe -Stream Zone.Identifier -ErrorAction SilentlyContinue)) {
            Write-Host 'Clearing the download marker ...'
            Get-ChildItem -Path $instance -Recurse -File | Unblock-File
        }

        # Best effort: a Start Menu entry is a courtesy, not the install.
        $startMenu = if ($env:APPDATA) { Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs' } else { $null }
        if ($startMenu -and (Test-Path $startMenu)) {
            try {
                $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut(
                    (Join-Path $startMenu "$app.lnk")
                )
                $shortcut.TargetPath = $exe
                $shortcut.WorkingDirectory = $instance
                $shortcut.Save()
                Write-Host "Start Menu: $(Join-Path $startMenu "$app.lnk")"
            }
            catch {
                Write-Host "No Start Menu entry: $($_.Exception.Message)"
            }
        }
    }
    finally {
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }
}

Write-Host "Installed:  $exe"
Write-Host "It keeps what it mirrors in $($env:LOCALAPPDATA)\confluence-export"
Write-Host 'Nothing is signed: Windows will show a SmartScreen prompt the first'
Write-Host 'time — More info, then Run anyway.'

try {
    Start-Process -FilePath $exe -WorkingDirectory $instance
    Write-Host "Running $exe"
}
catch {
    Write-Host "It is installed but could not be started: $($_.Exception.Message)"
    exit 1
}
