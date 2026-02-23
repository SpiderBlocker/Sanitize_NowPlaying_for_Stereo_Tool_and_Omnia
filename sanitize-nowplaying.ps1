#requires -version 5.1

# sanitize-nowplaying.ps1 (Windows PowerShell 5.1 - Wait-Event watcher)
#
# Input from Playout software:   %artist<sep>%title   (configurable; default separator U+241F "␟")
#
# Outputs for Stereo Tool, all encoded as UTF-8 (no BOM):
# - nowplaying_rt.txt        : RT text (or empty)
# - nowplaying_rtplus.txt    : RT+ tagged text (or empty)
# - nowplaying_prefix.txt    : prefix text (or empty; only when a valid RT exists)
#
# Console UI:
# - Always shows both RT and RT+ outputs.
# - Shows PREFIX OUT under INPUT in the live window.
# - Heartbeat status bar with clock + elapsed-since-update indicator.
#
# Notes:
# - UTF-8 is used end-to-end towards Stereo Tool.
# - The sanitizer can transliterate text (Greek/Cyrillic) to an RDS-safe Latin repertoire when ASCII-safe/transliteration is enabled.
#   When transliteration is OFF, it preserves Unicode (e.g., Greek/Cyrillic) while still stripping control/invisible chars.
# - Atomic writes are used to avoid partial reads by Stereo Tool during normal operation.
# - Terminal console QuickEdit is disabled to prevent the console from "freezing" when selecting text.

# -------------------- UTF-8 console setup (code page 65001) --------------------
try { & chcp 65001 > $null } catch { }
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
try { [Console]::InputEncoding  = New-Object System.Text.UTF8Encoding($false) } catch { }
try { $OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }


# -------------------- Shutdown flush (host-independent) -----------------------
# Uses a native Console Control Handler (CTRL+C, close button, ALT+F4, logoff/shutdown) to hard-truncate
# the output files as a last-resort, even when PowerShell finally blocks are not executed (e.g., ps2exe).
# The handler performs only .NET file truncation and never calls back into PowerShell (thread-safe).

try {
    Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public static class NativeExitFlush
{
    private delegate bool HandlerRoutine(int ctrlType);

    [DllImport("Kernel32.dll", SetLastError=true)]
    private static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

    // Volatile references to the active output paths.
    private static volatile string _prefix;
    private static volatile string _rt;
    private static volatile string _rtp;

    private static int _installed;
    private static readonly HandlerRoutine _handler = new HandlerRoutine(Handle);

    public static void Install()
    {
        if (Interlocked.Exchange(ref _installed, 1) != 0) return;
        try { SetConsoleCtrlHandler(_handler, true); } catch { }
        // Extra safety net: flush on normal process exit as well.
        try { AppDomain.CurrentDomain.ProcessExit += (s, e) => Flush(); } catch { }
    }

    public static void Update(string prefix, string rt, string rtp)
    {
        _prefix = prefix;
        _rt     = rt;
        _rtp    = rtp;
    }

    public static void Flush()
    {
        TryTruncate(_prefix);
        TryTruncate(_rt);
        TryTruncate(_rtp);
    }

    private static void TryTruncate(string path)
    {
        if (string.IsNullOrEmpty(path)) return;
        try
        {
            // FileShare.ReadWrite: avoid unnecessary failures when another process has the file open in shared mode.
            using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite))
            {
                fs.Flush(true);
            }
        }
        catch { }
    }

    private static bool Handle(int ctrlType)
    {
        // Always attempt flush, but do not "handle" the event.
        // Returning false lets PowerShell's CancelKeyPress/finally logic run when available,
        // while still ensuring the outputs are truncated for hard termination scenarios.
        Flush();
        return false;
    }
}
"@ -ErrorAction Stop
} catch { }

try { [NativeExitFlush]::Install() } catch { }

$ScriptTitle   = "Sanitize NowPlaying for Stereo Tool"
$ScriptVersion = "1.10.6"
# Console compatibility switches
# These toggles exist to reduce the risk of host-specific console crashes/quirks on some systems.
# Defaults preserve the current behavior.
$EnableConsoleFontTweak = $true      # Best-effort font selection (classic conhost only)
$EnableHardScrollLock   = $true      # Best-effort hard scrollback removal (classic conhost only)

# UI margins (requested): 1 blank row at top and 1 blank column at left.
$script:UiOffsetX     = 1
$script:UiOffsetY     = 1
$script:UiRightMargin = 1   # keep one free column at the right edge

# Console sizing (best-effort): keep the UI readable and stable.
$FixedConsoleWidth  = 110
$FixedConsoleHeight = 23

# -------------------------------------------------------------------------------------------------
# UI configuration
#
# Keep UI-related constants centralized here to avoid scattering hardcoded values throughout the code.
# IMPORTANT: Do not change these values unless you intend to change the visual appearance/behavior of the UI.
# -------------------------------------------------------------------------------------------------

# Base ConsoleColor palette (raw console colors)
$UI_Color_Background        = [ConsoleColor]::Black
$UI_Color_InputText         = [ConsoleColor]::Gray
$UI_Color_BrightText        = [ConsoleColor]::White
$UI_Color_DimText           = [ConsoleColor]::DarkGray
$UI_Color_WarningText       = [ConsoleColor]::Yellow
$UI_Color_WarningTextDim    = [ConsoleColor]::DarkYellow
$UI_Color_ErrorText         = [ConsoleColor]::DarkRed

# Semantic colors (output, input, prefix)
$UI_Color_Input             = [ConsoleColor]::DarkYellow
$UI_Color_Prefix            = [ConsoleColor]::Cyan
$UI_Color_RT                = [ConsoleColor]::Green
$UI_Color_RTPlus            = [ConsoleColor]::DarkCyan
$UI_Color_MenuFrame         = [ConsoleColor]::White

# Selection/inversion (used for menu highlighting, etc.)
$UI_Color_SelectedText      = [ConsoleColor]::Black
$UI_Color_SelectedBack      = [ConsoleColor]::DarkGray

# Timing (milliseconds)
$UI_ShortSleepMs            = 10
$UI_ToastDurationMs         = 1400

# Window title (best-effort)
$UI_WindowTitleTemplate     = "{0} - v{1}  © 2026 Loenie"

# Set the console window title (best-effort).
try { $host.UI.RawUI.WindowTitle = ($UI_WindowTitleTemplate -f $ScriptTitle, $ScriptVersion) } catch { }

$InFile = 'C:\RDS\nowplaying.txt'
$script:InFile = $InFile

# Determine whether the pre-existing input at startup is stale (startup-only safety gate).
try {
    if (Test-Path -LiteralPath $InFile -PathType Leaf) {
        $fi0  = Get-Item -LiteralPath $InFile -ErrorAction Stop
        $age0 = ([DateTime]::UtcNow - $fi0.LastWriteTimeUtc).TotalSeconds
        if ($age0 -gt $StartupPublishFreshSec) { $script:StartupInputWasExpired = $true }
    }
} catch { }

$PrefixFile = 'C:\RDS\nowplaying_prefix.txt'
$script:PrefixFile = $PrefixFile
$OutFileRt = 'C:\RDS\nowplaying_rt.txt'
$script:OutFileRt = $OutFileRt
$OutFileRtPlus = 'C:\RDS\nowplaying_rtplus.txt'
$script:OutFileRtPlus = $OutFileRtPlus
# -------------------------------------------------------------------------------------------------
# Persistent settings (single file)
#
# All persistent settings are stored in a single JSON file in the application directory.
# -------------------------------------------------------------------------------------------------

# -------------------------------------------------------------------------------------------------
# Determine application base directory
# - When running as a normal .ps1, this equals the script directory.
# - When compiled with ps2exe, $AppBaseDir can be empty; in that case we fall back to the EXE directory.
# -------------------------------------------------------------------------------------------------

$AppBaseDir = $null

# Preferred: normal .ps1 execution context
try {
    if ($PSCommandPath) { $AppBaseDir = Split-Path -Parent $PSCommandPath }
} catch { }

# ps2exe / host fallbacks
if ([string]::IsNullOrWhiteSpace($AppBaseDir)) {
    try { $AppBaseDir = [AppDomain]::CurrentDomain.BaseDirectory } catch { }
}
if ([string]::IsNullOrWhiteSpace($AppBaseDir)) {
    try {
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exePath) { $AppBaseDir = Split-Path -Parent $exePath }
    } catch { }
}
if ([string]::IsNullOrWhiteSpace($AppBaseDir)) {
    try { $AppBaseDir = (Get-Location).Path } catch { $AppBaseDir = '.' }
}

$SettingsFile = Join-Path $AppBaseDir 'Sanitize-NowPlaying.settings.json'

# In-memory settings (defaults).
$script:Settings = @{
    WorkDir                = ''     # Optional. If set, all IO paths below are derived from this directory.
    PrefixLanguageCode     = 'EN'
    TransliterationEnabled = $true
    AsciiSafeEnabled       = $false
    WorkDirWizardDone      = $false
    DelimiterKey       = 'U241F'  # One of: U241F, TAB, CUSTOM
    DelimiterCustom    = '' # Used when DelimiterKey = CUSTOM
}

function Get-HashtableFromPsObject($obj) {
    if ($null -eq $obj) { return @{} }
    if ($obj -is [System.Collections.IDictionary]) { return @{} + $obj }
    $ht = @{}
    foreach ($p in $obj.PSObject.Properties) { $ht[$p.Name] = $p.Value }
    return $ht
}

function Save-Settings {
    try {
        $json = ($script:Settings | ConvertTo-Json -Depth 6)
        $tmp  = [System.IO.Path]::Combine($AppBaseDir, ('~settings_{0}.tmp' -f ([System.Guid]::NewGuid().ToString('N'))))
        [System.IO.File]::WriteAllText($tmp, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($true)))
        Move-Item -LiteralPath $tmp -Destination $SettingsFile -Force
    } catch {
        try { if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
    }
}

function Load-Settings {
    # 1) Load JSON if present.
    if (Test-Path $SettingsFile) {
        try {
            $raw = Get-Content -LiteralPath $SettingsFile -Raw -ErrorAction Stop
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            $ht  = Get-HashtableFromPsObject $obj

            foreach ($k in @('WorkDir','PrefixLanguageCode','TransliterationEnabled','AsciiSafeEnabled','WorkDirWizardDone','DelimiterKey','DelimiterCustom')) {
                if ($ht.ContainsKey($k)) { $script:Settings[$k] = $ht[$k] }
            }
        } catch { }
        return
    }


    # 2) First run: create the settings file with defaults.

    Save-Settings
}

function Ensure-Directory([string]$dir, [string]$purpose) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
    if (Test-Path -LiteralPath $dir) { return $true }

    try {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Ensure-WorkDirOrFallback {
    # Ensure the current working directory exists, or fall back to a writable directory.
    $wanted = ''
    try { $wanted = Split-Path -Parent $script:InFile } catch { $wanted = '' }

    # Do not implicitly create the default directory on first run. The user must confirm creation in the WorkDir wizard.
    $wizardDone = $false
    try { $wizardDone = [bool]$script:Settings.WorkDirWizardDone } catch { $wizardDone = $false }

    if ($wanted -and (Test-Path -LiteralPath $wanted)) { return $wanted }
    if ($wanted -and $wizardDone -and (Ensure-Directory $wanted "WorkDir")) { return $wanted }

    # Fallbacks that are typically writable without admin rights.
    $candidates = @(
        (Join-Path $env:ProgramData "RDS"),
        (Join-Path $env:LOCALAPPDATA "RDS")
    )

    foreach ($c in $candidates) {
        if (Ensure-Directory $c "Fallback WorkDir") {
            # Persist and switch all IO paths to the fallback directory.
            $script:Settings.WorkDir = $c
            $script:Settings.WorkDirWizardDone = $true
            Save-Settings

            Set-WorkDirPaths $c
            return $c
        }
    }

    return $null
}

function Set-WorkDirPaths([string]$dir) {
    # Centralized path derivation for all workdir-dependent files.
    # NOTE: Uses the same variable names/assignments as the original inline blocks (behavior-preserving).
    $InFile              = Join-Path $dir 'nowplaying.txt'
    $script:InFile       = $InFile
    $PrefixFile          = Join-Path $dir 'nowplaying_prefix.txt'
    $script:PrefixFile   = $PrefixFile
    $OutFileRt           = Join-Path $dir 'nowplaying_rt.txt'
    $script:OutFileRt    = $OutFileRt
    $OutFileRtPlus       = Join-Path $dir 'nowplaying_rtplus.txt'
    $script:OutFileRtPlus = $OutFileRtPlus

    try { [NativeExitFlush]::Update($script:PrefixFile, $script:OutFileRt, $script:OutFileRtPlus) } catch { }

}

function Apply-WorkDirIfConfigured {
    if (-not $script:Settings.WorkDir) { return }
    $dir = $script:Settings.WorkDir.Trim()
    if (-not $dir) { return }
    if (-not (Ensure-Directory $dir "Configured WorkDir")) { return }
    $script:Settings.WorkDir = $dir

    Set-WorkDirPaths $dir
}

function Show-WorkDirWizardIfNeeded {
    # Show a one-time first-run wizard (modal popup). If it has been completed and the directory exists,
    # it will not show again.
    $dir  = ($script:Settings.WorkDir | ForEach-Object { "$_".Trim() })
    $done = $false
    try { $done = [bool]$script:Settings.WorkDirWizardDone } catch { }

    # Ensure the fixed console layout is applied even before the first full UI render.
    # This matters on first run, where the WorkDir wizard appears before the main UI is initialized.
    try { Ensure-MinConsoleLayout } catch { }

    if ($done -and $dir -and (Test-Path -LiteralPath $dir)) { return }
    if ($done -and (-not $dir))                             { return }

    $null = Show-WorkDirMenu -MarkWizardDone
}

# -------------------------------------------------------------------------------------------------
# Prefix language selection (non-blocking UI)
#
# The prefix is written to the separate prefix output file and is shown in the console UI.
# Many receivers are conservative with character support. For maximum robustness your pipeline
# already sanitizes the prefix through the same ASCII/RDS-safe passes as other text.
# -------------------------------------------------------------------------------------------------

# Supported languages (Native prefix + ASCII-safe fallback).
# NOTE: Keep a trailing space after ':' to match the existing output formatting.
$PrefixLanguages = @(
    @{ Code='EN'; Name='English';            Native='Now playing: ';            Ascii='Now playing: ' }
    @{ Code='NL'; Name='Nederlands';         Native='Je hoort nu: ';            Ascii='Je hoort nu: ' }
    @{ Code='DE'; Name='Deutsch';            Native='Jetzt läuft: ';            Ascii='Jetzt laeuft: ' }
    @{ Code='FR'; Name='Français';           Native='À l''écoute: ';            Ascii='A l''ecoute: ' }
    @{ Code='ES'; Name='Español';            Native='Ahora suena: ';            Ascii='Ahora suena: ' }
    @{ Code='PT'; Name='Português';          Native='A tocar agora: ';          Ascii='A tocar agora: ' }
    @{ Code='IT'; Name='Italiano';           Native='In riproduzione: ';        Ascii='In riproduzione: ' }
    @{ Code='DA'; Name='Dansk';              Native='Nu spiller: ';             Ascii='Nu spiller: ' }
    @{ Code='SV'; Name='Svenska';            Native='Spelas nu: ';              Ascii='Spelas nu: ' }
    @{ Code='NO'; Name='Norsk';              Native='Spilles nå: ';             Ascii='Spilles naa: ' }
    @{ Code='FI'; Name='Suomi';              Native='Nyt soi: ';                Ascii='Nyt soi: ' }
    @{ Code='IS'; Name='Íslenska';           Native='Í spilun núna: ';          Ascii='I spilun nuna: ' }
    @{ Code='ET'; Name='Eesti';              Native='Hetkel mängib: ';          Ascii='Hetkel mangib: ' }
    @{ Code='LV'; Name='Latviešu';           Native='Tagad skan: ';             Ascii='Tagad skan: ' }
    @{ Code='LT'; Name='Lietuvių';           Native='Dabar groja: ';            Ascii='Dabar groja: ' }
    @{ Code='PL'; Name='Polski';             Native='Teraz gra: ';              Ascii='Teraz gra: ' }
    @{ Code='CS'; Name='Čeština';            Native='Právě hraje: ';            Ascii='Prave hraje: ' }
    @{ Code='SK'; Name='Slovenčina';         Native='Práve hrá: ';              Ascii='Prave hra: ' }
    @{ Code='HU'; Name='Magyar';             Native='Most szól: ';              Ascii='Most szol: ' }
    @{ Code='RO'; Name='Română';             Native='Acum se aude: ';           Ascii='Acum se aude: ' }
    @{ Code='SL'; Name='Slovenščina';        Native='Trenutno se predvaja: ';   Ascii='Trenutno se predvaja: ' }
    @{ Code='HR'; Name='Hrvatski';           Native='Sada svira: ';             Ascii='Sada svira: ' }
    @{ Code='BS'; Name='Bosanski';           Native='Sada svira: ';             Ascii='Sada svira: ' }
    @{ Code='MK'; Name='Makedonski (Latin)'; Native='Momentalno sviri: ';       Ascii='Momentalno sviri: ' }
    @{ Code='SQ'; Name='Shqip';              Native='Tani po luhet: ';          Ascii='Tani po luhet: ' }
    @{ Code='TR'; Name='Türkçe';             Native='Şimdi çalıyor: ';          Ascii='Simdi caliyor: ' }
    @{ Code='EL'; Name='Ελληνικά';           Native='Τώρα παίζει: ';            Ascii='Tora paizei: ' }
    @{ Code='RU'; Name='Русский';            Native='Сейчас играет: ';          Ascii='Seichas igraet: ' }
    @{ Code='SR'; Name='Srpski';             Native='Сада свира: ';             Ascii='Sada svira: ' }
    @{ Code='BG'; Name='Български';          Native='Сега звучи: ';             Ascii='Sega zvuchi: ' }
    @{ Code='UK'; Name='Українська';         Native='Зараз грає: ';             Ascii='Zaraz hraie: ' }
    @{ Code='BE'; Name='Беларуская';         Native='Зараз грае: ';             Ascii='Zaraz hrae: ' }
)

# -------------------------------------------------------------------------------------------------
# Transliteration control (Greek + Cyrillic)
#
# Default is ON for maximum robustness, because RDS RadioText is largely Latin-only on many receivers.
# Transliteration can be changed via the F10 Settings menu (persisted to the unified settings JSON file).
# -------------------------------------------------------------------------------------------------

# -------------------------------------------------------------------------------------------------
# Unified settings helpers (consolidation)
# -------------------------------------------------------------------------------------------------

function Load-SettingBool([string]$key, [object]$default) {
    try {
        if ($script:Settings -and $script:Settings.ContainsKey($key)) {
            return [bool]$script:Settings[$key]
        }
    } catch { }
    return [bool]$default
}

function Save-SettingBool([string]$key, [bool]$value) {
    if (-not $script:Settings) { return }
    $script:Settings[$key] = [bool]$value
    Save-Settings
}

function Load-SettingStringUpper([string]$key, [string]$default = "") {
    try {
        if ($script:Settings -and $script:Settings.ContainsKey($key) -and $script:Settings[$key]) {
            return "$($script:Settings[$key])".Trim().ToUpperInvariant()
        }
    } catch { }
    return "$default".Trim().ToUpperInvariant()
}

function Save-SettingStringUpper([string]$key, [string]$value) {
    if (-not $script:Settings) { return }
    $script:Settings[$key] = "$value".Trim().ToUpperInvariant()
    Save-Settings
}

function Load-TransliterationSetting {
    # Settings are loaded once at startup from $SettingsFile into $script:Settings.
    $script:TransliterationEnabled = Load-SettingBool 'TransliterationEnabled' $script:Settings.TransliterationEnabled
}

function Save-TransliterationSetting {
    Save-SettingBool 'TransliterationEnabled' $script:TransliterationEnabled
}

function Apply-DelimiterFromSettings {
    # Delimiter is configurable to support different playout integrations.
    # Parsing rule is conservative:
    # - Exactly ONE delimiter occurrence -> split into Artist + Title
    # - Otherwise                     -> treat as title-only (Artist empty)
    $key = 'U241F'
    try {
        if ($script:Settings.ContainsKey('DelimiterKey') -and $script:Settings.DelimiterKey) {
            $key = "$($script:Settings.DelimiterKey)".Trim().ToUpperInvariant()
        }
    } catch { }

    switch ($key) {
        'TAB'    { $script:DelimiterKey = 'TAB';    $script:SepChar = "`t";         $script:SepGlyph = 'TAB' }
        'CUSTOM' {
            $custom = ''
            try {
                if ($script:Settings -and $script:Settings.ContainsKey('DelimiterCustom')) { $custom = [string]$script:Settings.DelimiterCustom }
            } catch { $custom = '' }
            if ($null -eq $custom) { $custom = '' }
            $custom = $custom.Trim()

            if ([string]::IsNullOrEmpty($custom)) {
                # Invalid / empty custom delimiter -> fall back to the default.
                $script:DelimiterKey = 'U241F'
                $script:SepChar  = [char]0x241F
                $script:SepGlyph = [char]0x241F
            } else {
                $script:DelimiterKey = 'CUSTOM'
                $script:SepChar  = $custom
                $script:SepGlyph = $custom
            }
        }
        default  { $script:DelimiterKey = 'U241F';  $script:SepChar = [char]0x241F; $script:SepGlyph = [char]0x241F }
    }

    # Backward compatibility: older builds and some hosts may expect globals.
    $global:SepChar  = $script:SepChar
    $global:SepGlyph = $script:SepGlyph
}

function Save-DelimiterSetting {
    if (-not $script:Settings) { return }

    $script:Settings.DelimiterKey = "$script:DelimiterKey".Trim().ToUpperInvariant()

    if ($script:Settings.DelimiterKey -eq 'CUSTOM') {
        # Persist the actual delimiter string as well.
        # IMPORTANT: when the user just entered a new custom delimiter, $script:SepChar may still hold the old value
        # until Apply-DelimiterFromSettings runs. Therefore we prefer the value already present in Settings.
        $custom = ''
        try {
            if ($script:Settings.ContainsKey('DelimiterCustom')) { $custom = [string]$script:Settings.DelimiterCustom }
        } catch { $custom = '' }

        if ($null -eq $custom) { $custom = '' }
        $custom = $custom.Trim()

        if ([string]::IsNullOrEmpty($custom)) {
            # Fall back to the current runtime delimiter (best effort).
            try { $custom = [string]$script:SepChar } catch { $custom = '' }
            if ($null -eq $custom) { $custom = '' }
            $custom = $custom.Trim()
        }

        $script:Settings.DelimiterCustom = $custom
    }

    Save-Settings
}

# Load persisted setting (if any).
Load-TransliterationSetting

# -------------------------------------------------------------------------------------------------
# Global ASCII-safe control (entire RT/RT+ and the prefix)
#
# When enabled, output is forced through the conservative Latin/ASCII-oriented final pass used for RDS robustness.
# This is independent of the prefix language selection. If you enable ASCII-safe while transliteration is OFF,
# the script will temporarily force transliteration ON to avoid silently dropping Greek/Cyrillic. When ASCII-safe
# is turned OFF again, the previous transliteration state is restored.
# -------------------------------------------------------------------------------------------------

$script:AsciiSafeEnabled = $false
$script:TranslitForcedByAsciiSafe = $false
$script:TranslitPrevBeforeAsciiSafe = $true

function Load-AsciiSafeSetting {
    # Settings are loaded once at startup from $SettingsFile into $script:Settings.
    $script:AsciiSafeEnabled = Load-SettingBool 'AsciiSafeEnabled' $script:Settings.AsciiSafeEnabled
}

function Save-AsciiSafeSetting {
    Save-SettingBool 'AsciiSafeEnabled' $script:AsciiSafeEnabled
}

Load-AsciiSafeSetting

function Get-PrefixLanguageIndex([string]$code) {
    for ($i = 0; $i -lt $PrefixLanguages.Count; $i++) {
        if ($PrefixLanguages[$i].Code -eq $code) { return $i }
    }
    return 0
}

function Load-PrefixLanguageSetting {
    # Settings are loaded once at startup from $SettingsFile into $script:Settings.
    $script:PrefixLanguageCode = Load-SettingStringUpper 'PrefixLanguageCode' $script:Settings.PrefixLanguageCode
}

function Save-PrefixLanguageSetting {
    Save-SettingStringUpper 'PrefixLanguageCode' $script:PrefixLanguageCode
}

function Apply-PrefixFromLanguage {
    $idx = Get-PrefixLanguageIndex $script:PrefixLanguageCode
    $entry = $PrefixLanguages[$idx]
    $script:PrefixTextNative = $entry.Native
    $script:PrefixTextAscii  = $entry.Ascii
}

# Load persisted selection (if any) and apply.
Load-PrefixLanguageSetting
Apply-PrefixFromLanguage

# -------------------------------------------------------------------------------------------------

$MaxLen = 64
$DebounceMs = 250

# Heartbeat refresh cadence (seconds).
$PollTimeoutSec = 1

$ReadRetryCount = 20
$ReadRetryDelayMs = 50

$SepChar  = [char]0x241F  # Configurable delimiter for the playout integration
$SepGlyph = [char]0x241F  # Display label for the current delimiter
$OutJoin  = " - "

# Stop flag (cooperative shutdown).
$script:Stopping = $false
$script:RebuildWatcher = $false

# Tracks whether output files have been flushed due to missing input (prevents repeated writes).
$script:OutputsFlushedForNotAvailable = $false

# -------------------- Minimal startup toast (no dependencies) -----------------
function Show-StartupToast {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [int]$Seconds = 2
    )

    try {
        # Ensure we are writing to a real console window.
        if (-not $Host.UI -or -not $Host.UI.RawUI) { return }

        $raw = $Host.UI.RawUI
        $w = [Math]::Max(20, $raw.WindowSize.Width)
        $h = [Math]::Max(5,  $raw.WindowSize.Height)

        # Basic box geometry (centered, like a modal toast).
        $padX = 2
        $msg = $Message.Trim()
        if ($msg.Length -gt ($w - 6)) { $msg = $msg.Substring(0, $w - 9) + "..." }

        $boxW = [Math]::Min($w - 2, [Math]::Max(20, $msg.Length + 6))
        $left = [Math]::Max(0, [int](($w - $boxW) / 2))
        $top  = [Math]::Max(0, [int](($h - 5) / 2))

        # Draw
        $origFg = $raw.ForegroundColor
        $origBg = $raw.BackgroundColor

        $raw.ForegroundColor = "Gray"
        $raw.BackgroundColor = "Black"

        $lineTop = "┌" + ("─" * ($boxW - 2)) + "┐"
        $lineMid = "│" + (" " * ($boxW - 2)) + "│"
        $lineBot = "└" + ("─" * ($boxW - 2)) + "┘"

        [Console]::SetCursorPosition($left, $top)
        [Console]::Write($lineTop)
        [Console]::SetCursorPosition($left, $top + 1)
        [Console]::Write($lineMid)
        [Console]::SetCursorPosition($left, $top + 2)
        [Console]::Write("│" + (" " * $padX) + $msg.PadRight($boxW - 2 - ($padX * 2)) + (" " * $padX) + "│")
        [Console]::SetCursorPosition($left, $top + 3)
        [Console]::Write($lineMid)
        [Console]::SetCursorPosition($left, $top + 4)
        [Console]::Write($lineBot)

        Start-Sleep -Seconds ([Math]::Max(1, $Seconds))
        $raw.ForegroundColor = $origFg
        $raw.BackgroundColor = $origBg
    } catch {
        # Last resort: write a normal line.
        try { Write-Host $Message } catch { }
        try { Start-Sleep -Seconds ([Math]::Max(1, $Seconds)) } catch { }
    }
}

# -------------------- One-instance guard (Local named mutex) ------------------
# Prevent multiple instances from running simultaneously (per logon session).
$MutexName = "Local\SanitizeNowPlayingForStereoTool"
$script:Mutex = $null
$script:MutexHasHandle = $false

try {
    $createdNew = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)

    if (-not $createdNew) {
        if (-not $script:Mutex.WaitOne(0, $false)) {
            Show-StartupToast -Message "Another instance is already running." -Seconds 2
            exit 0
        }
    }

    $script:MutexHasHandle = $true
} catch {
    $script:Mutex = $null
    $script:MutexHasHandle = $false
}

# -------------------- Health / elapsed color tuning ---------------------------
$HealthGraceSec = 120  # 2 minutes grace
$HealthRedAtSec = 900  # 15 minutes to full red

# -------------------- Console host fixes --------------------------------------

function Disable-ConsoleQuickEdit {
    try {
        if (-not ("Win.ConsoleModeNative" -as [type])) {
            Add-Type -TypeDefinition @"
namespace Win {
    using System;
    using System.Runtime.InteropServices;

    public static class ConsoleModeNative {
        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out int lpMode);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool SetConsoleMode(IntPtr hConsoleHandle, int dwMode);

        public const int STD_INPUT_HANDLE = -10;
        public const int ENABLE_QUICK_EDIT_MODE = 0x0040;
        public const int ENABLE_EXTENDED_FLAGS  = 0x0080;
        public const int ENABLE_MOUSE_INPUT    = 0x0010;
    }
}
"@
        }

        $h = [Win.ConsoleModeNative]::GetStdHandle([Win.ConsoleModeNative]::STD_INPUT_HANDLE)
        if ($h -eq [IntPtr]::Zero) { return }

        $mode = 0
        if (-not [Win.ConsoleModeNative]::GetConsoleMode($h, [ref]$mode)) { return }

        $mode = $mode -bor [Win.ConsoleModeNative]::ENABLE_EXTENDED_FLAGS
        $mode = $mode -band (-bnot [Win.ConsoleModeNative]::ENABLE_QUICK_EDIT_MODE)
        $mode = $mode -band (-bnot [Win.ConsoleModeNative]::ENABLE_MOUSE_INPUT)

        [void][Win.ConsoleModeNative]::SetConsoleMode($h, $mode)
    } catch { }
}

function Clear-ConsoleSelectionIfActive {
    # Best-effort mitigation for Ctrl+A "Select All" freezing the console host.
    # When selection is active, conhost suspends screen updates. We detect this and cancel via ESC.
    try {
        if (-not ("Win.ConsoleSelectionNative" -as [type])) {
            Add-Type -TypeDefinition @"
namespace Win {
    using System;
    using System.Runtime.InteropServices;

    public static class ConsoleSelectionNative {
        [StructLayout(LayoutKind.Sequential)]
        public struct CONSOLE_SELECTION_INFO {
            public uint dwFlags;
            public COORD dwSelectionAnchor;
            public SMALL_RECT srSelection;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct COORD { public short X; public short Y; }

        [StructLayout(LayoutKind.Sequential)]
        public struct SMALL_RECT { public short Left; public short Top; public short Right; public short Bottom; }

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool GetConsoleSelectionInfo(out CONSOLE_SELECTION_INFO lpConsoleSelectionInfo);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

        public const uint WM_KEYDOWN = 0x0100;
        public const uint WM_KEYUP   = 0x0101;
        public const int VK_ESCAPE   = 0x1B;

        public const uint CONSOLE_SELECTION_IN_PROGRESS = 0x0001;
        public const uint CONSOLE_SELECTION_NOT_EMPTY   = 0x0002;
    }
}
"@
        }

        $sel = New-Object Win.ConsoleSelectionNative+CONSOLE_SELECTION_INFO
        if (-not [Win.ConsoleSelectionNative]::GetConsoleSelectionInfo([ref]$sel)) { return }

        if (($sel.dwFlags -band [Win.ConsoleSelectionNative]::CONSOLE_SELECTION_IN_PROGRESS) -ne 0 -or
            ($sel.dwFlags -band [Win.ConsoleSelectionNative]::CONSOLE_SELECTION_NOT_EMPTY) -ne 0) {

            $hwnd = [Win.ConsoleSelectionNative]::GetConsoleWindow()
            if ($hwnd -ne [IntPtr]::Zero) {
                # ESC cancels selection/mark mode in conhost.
                [void][Win.ConsoleSelectionNative]::PostMessage($hwnd, [Win.ConsoleSelectionNative]::WM_KEYDOWN, [IntPtr][Win.ConsoleSelectionNative]::VK_ESCAPE, [IntPtr]::Zero)
                [void][Win.ConsoleSelectionNative]::PostMessage($hwnd, [Win.ConsoleSelectionNative]::WM_KEYUP,   [IntPtr][Win.ConsoleSelectionNative]::VK_ESCAPE, [IntPtr]::Zero)
            }
        }
    } catch { }
}

function Set-ConsoleFontBestEffort {
    param(
        [string[]]$PreferredFonts = @("Cascadia Mono","Cascadia Code","Consolas"),
        [int]$FontHeight = 16
    )

    try {
        if (-not ("Win.ConsoleFontNative" -as [type])) {
            Add-Type -TypeDefinition @"
namespace Win {
    using System;
    using System.Runtime.InteropServices;

    public static class ConsoleFontNative {
        [StructLayout(LayoutKind.Sequential)]
        public struct COORD { public short X; public short Y; }

        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
        public struct CONSOLE_FONT_INFOEX {
            public uint cbSize;
            public uint nFont;
            public COORD dwFontSize;
            public int FontFamily;
            public int FontWeight;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)]
            public string FaceName;
        }

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern bool GetCurrentConsoleFontEx(
            IntPtr hConsoleOutput,
            bool bMaximumWindow,
            ref CONSOLE_FONT_INFOEX lpConsoleCurrentFontEx
        );

        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern bool SetCurrentConsoleFontEx(
            IntPtr hConsoleOutput,
            bool bMaximumWindow,
            ref CONSOLE_FONT_INFOEX lpConsoleCurrentFontEx
        );

        public const int STD_OUTPUT_HANDLE = -11;
    }
}
"@
        }

        $hOut = [Win.ConsoleFontNative]::GetStdHandle([Win.ConsoleFontNative]::STD_OUTPUT_HANDLE)
        if ($hOut -eq [IntPtr]::Zero) { return }

        $cfi = New-Object Win.ConsoleFontNative+CONSOLE_FONT_INFOEX
        $cfi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($cfi)

        if (-not [Win.ConsoleFontNative]::GetCurrentConsoleFontEx($hOut, $false, [ref]$cfi)) { return }

        try {
            if ($FontHeight -gt 0 -and $FontHeight -lt 100) { $cfi.dwFontSize.Y = [int16]$FontHeight }
        } catch { }

        foreach ($name in $PreferredFonts) {
            try {
                $old = $cfi.FaceName
                $cfi.FaceName = $name
                if ([Win.ConsoleFontNative]::SetCurrentConsoleFontEx($hOut, $false, [ref]$cfi)) { return }
                $cfi.FaceName = $old
            } catch { }
        }
    } catch { }
}
Disable-ConsoleQuickEdit

# Font changing via SetCurrentConsoleFontEx is known to be unstable on some console hosts.
# Only attempt it in classic conhost sessions (best-effort).
try {
    $isWindowsTerminal = [bool]$env:WT_SESSION
    if (-not $isWindowsTerminal -and $EnableConsoleFontTweak) {
        Set-ConsoleFontBestEffort -FontHeight 16
    }
} catch { }

try { Clear-Host } catch { }
try { [Console]::CursorVisible = $false } catch { }

$script:BaseFg = $UI_Color_InputText
$script:BaseBg = [Console]::BackgroundColor
try {
    [Console]::ForegroundColor = $script:BaseFg
    [Console]::BackgroundColor = $script:BaseBg
} catch { }

# -------------------- Console primitives --------------------------------------

function With-ConsoleColor([ConsoleColor]$fg, [ConsoleColor]$bg, [scriptblock]$action) {
    $oldFg = [Console]::ForegroundColor
    $oldBg = [Console]::BackgroundColor
    try {
        [Console]::ForegroundColor = $fg
        [Console]::BackgroundColor = $bg
        & $action
    } finally {
        [Console]::ForegroundColor = $oldFg
        [Console]::BackgroundColor = $oldBg
    }
}

function Pad-OrEllipsize([string]$s, [int]$width) {
    if ($null -eq $s) { $s = "" }
    if ($width -lt 4) { return $s }
    if ($s.Length -gt $width) { return ($s.Substring(0, $width - 3) + "...") }
    return $s
}

function Show-LanguageMenu {
    $prevOverlay = $script:UiOverlayActive
    $script:UiOverlayActive = $true
    Lock-ConsoleScrolling
    try {
    # Modal language selection UI (opened from the Settings menu).
    # Keys: Up/Down = navigate, Enter = select, Esc = cancel.
    try { [Console]::CursorVisible = $false } catch { }
    Lock-ConsoleScrolling

    $winW = [Math]::Max(40, ([Console]::WindowWidth - $script:UiOffsetX - $script:UiRightMargin))
    $winH = [Math]::Max(10, [Console]::WindowHeight)

    $title = "Select prefix language"
    $help  = $(if ($StageOnly) { "Up/Down: move   Enter: select   Esc: cancel" } else { "Up/Down: move   Enter: apply   Esc: cancel" })
    $menuW = [Math]::Min($winW - 4, 78)
    $minW = [Math]::Min($winW - 4, 52)
    if ($menuW -lt $minW) { $menuW = $minW }
    $menuH = [Math]::Min($winH - 6, 18)
    $x0 = [Math]::Max(0, [int](($winW - $menuW) / 2))
    $y0 = [Math]::Max(0, [int](($winH - $menuH) / 2))

    $selected = Get-PrefixLanguageIndex $script:PrefixLanguageCode

    $translitHintCodes = @("EL","RU","SR","BG","UK","BE")
    $translitHintPad = 0
    if (-not $script:AsciiSafeEnabled -and $script:TransliterationEnabled) {
        foreach ($e2 in $PrefixLanguages) {
            if ($e2.Code -in $translitHintCodes) {
                $n2 = $e2.Native.Trim().Length
                if ($n2 -gt $translitHintPad) { $translitHintPad = $n2 }
            }
        }
    }

    # Ensure the currently selected language is visible immediately when opening the menu.
    $listH0 = $menuH - 5
    if ($PrefixLanguages.Count -le $listH0) {
        $top = 0
    } else {
        $half = [int]([Math]::Floor($listH0 / 2))
        $top = [Math]::Max(0, [Math]::Min($PrefixLanguages.Count - $listH0, $selected - $half))
    }

    function _DrawMenu {
        # Border and title
        Draw-MenuFrame $x0 $y0 $menuW $title $help

        $listH = $menuH - 5
        for ($i = 0; $i -lt $listH; $i++) {
            $idx = $top + $i
            $lineY = $y0 + 4 + $i

            $borderFg = $UI_Color_MenuFrame
            $borderBg = [Console]::BackgroundColor

            if ($idx -ge $PrefixLanguages.Count) {
                # Empty filler line (keep the border in one consistent color).
                With-ConsoleColor $borderFg $borderBg {
                    Set-UiCursorPosition $x0 $lineY
                    [Console]::Write("│")
                }
                With-ConsoleColor $itemFg $borderBg {
                    Set-UiCursorPosition ($x0 + 1) $lineY
                    [Console]::Write((" " * ($menuW - 2)))
                }
                With-ConsoleColor $borderFg $borderBg {
                    Set-UiCursorPosition ($x0 + $menuW - 1) $lineY
                    [Console]::Write("│")
                }
                continue
            }

            $e = $PrefixLanguages[$idx]
            $p = $(if ($script:AsciiSafeEnabled) { $e.Ascii } else { $e.Native })

            # Visual hint: when transliteration is enabled (and ASCII-safe is not), show the original script
            # plus the actual output form for Greek/Cyrillic prefixes.
            $pShown = $p.Trim()
            if (-not $script:AsciiSafeEnabled -and $script:TransliterationEnabled -and ($e.Code -in @("EL","RU","SR","BG","UK","BE"))) {
                $native0 = $e.Native.Trim()
                $nativePadded = $(if ($translitHintPad -gt 0) { $native0.PadRight($translitHintPad) } else { $native0 })
                $pShown = ("{0} -> {1}" -f $nativePadded, $e.Ascii.Trim())
            }

            $label = ("{0}  {1}  {2}" -f $e.Code.PadRight(3), $e.Name.PadRight(18), $pShown)

            $content = " " + $label
            if ($content.Length -gt ($menuW - 4)) { $content = $content.Substring(0, $menuW - 4) }
            $content = $content.PadRight($menuW - 4)

            # Draw with a constant border color, independent from the line's text highlighting.
            With-ConsoleColor $borderFg $borderBg {
                Set-UiCursorPosition $x0 $lineY
                [Console]::Write("│")
            }

            $inner = " " + $content + " "
            if ($idx -eq $selected) {
                With-ConsoleColor $UI_Color_SelectedText $UI_Color_SelectedBack {
                    Set-UiCursorPosition ($x0 + 1) $lineY
                    [Console]::Write($inner)
                }
            } else {
                With-ConsoleColor ($UI_Color_InputText) $borderBg {
                    Set-UiCursorPosition ($x0 + 1) $lineY
                    [Console]::Write($inner)
                }
            }

            With-ConsoleColor $borderFg $borderBg {
                Set-UiCursorPosition ($x0 + $menuW - 1) $lineY
                [Console]::Write("│")
            }
        }

        Write-At $x0 ($y0 + $menuH - 1) ("└" + ("─" * ($menuW - 2)) + "┘") ($UI_Color_MenuFrame)
        try { [Console]::CursorVisible = $false } catch { }
    }

    _DrawMenu
    while ($true) {
                if (-not [Console]::KeyAvailable) {
        Start-Sleep -Milliseconds $UI_ShortSleepMs
        Invoke-MenuIdleTick
        continue
        }
        $k = [Console]::ReadKey($true)


        if ($k.Key -eq [ConsoleKey]::Escape) { Restore-UiAfterMenu $y0 $menuH; return $false }

        if ($k.Key -eq [ConsoleKey]::UpArrow) {
            if ($selected -gt 0) { $selected-- }
        } elseif ($k.Key -eq [ConsoleKey]::DownArrow) {
            if ($selected -lt ($PrefixLanguages.Count - 1)) { $selected++ }
        } elseif ($k.Key -eq [ConsoleKey]::PageUp) {
            $selected = [Math]::Max(0, $selected - 10)
        } elseif ($k.Key -eq [ConsoleKey]::PageDown) {
            $selected = [Math]::Min($PrefixLanguages.Count - 1, $selected + 10)
        }
elseif ($k.Key -eq [ConsoleKey]::Enter) {
            $script:PrefixLanguageCode = $PrefixLanguages[$selected].Code
            Save-PrefixLanguageSetting
            Apply-PrefixFromLanguage
            Restore-UiAfterMenu $y0 $menuH
            return $true
        }

        # Keep selection visible
        $listH = $menuH - 5
        if ($selected -lt $top) { $top = $selected }
        if ($selected -ge ($top + $listH)) { $top = $selected - $listH + 1 }

        _DrawMenu
    }
    } finally {
        $script:UiOverlayActive = $prevOverlay
    }
}

function Show-OnOffMenu([string]$title, [bool]$currentValue) {
    $prevOverlay = $script:UiOverlayActive
    $script:UiOverlayActive = $true
    try {
        try { [Console]::CursorVisible = $false } catch { }

        $winW = [Math]::Max(44, ([Console]::WindowWidth - $script:UiOffsetX - $script:UiRightMargin))
        $winH = [Math]::Max(10, [Console]::WindowHeight)
    $help  = $(if ($StageOnly) { "Up/Down: move   Enter: select   Esc: cancel" } else { "Up/Down: move   Enter: apply   Esc: cancel" })
        $items = @(
            @{ Label = "ON";  Value = $true  }
            @{ Label = "OFF"; Value = $false }
        )

        $menuW = [Math]::Min($winW - 4, 34)
        $menuH = [Math]::Min($winH - 6, 8)
        $x0 = [Math]::Max(0, [int](($winW - $menuW) / 2))
        $y0 = [Math]::Max(0, [int](($winH - $menuH) / 2))

        $selected = $(if ($currentValue) { 0 } else { 1 })
        function _DrawMenu {
            Draw-MenuFrame $x0 $y0 $menuW $title $help

            $borderFg = $UI_Color_MenuFrame
            $borderBg = [Console]::BackgroundColor

            for ($i = 0; $i -lt 2; $i++) {
                $lineY = $y0 + 4 + $i
                $label = " " + $items[$i].Label
                $label = $label.PadRight($menuW - 4)
                $inner = " " + $label + " "

                With-ConsoleColor $borderFg $borderBg { Set-UiCursorPosition $x0 $lineY; [Console]::Write("│") }

                if ($i -eq $selected) {
                    With-ConsoleColor ($UI_Color_SelectedText) ($UI_Color_SelectedBack) {
                        Set-UiCursorPosition ($x0 + 1) $lineY; [Console]::Write($inner)
                    }
                } else {
                    With-ConsoleColor ($UI_Color_InputText) $borderBg {
                        Set-UiCursorPosition ($x0 + 1) $lineY; [Console]::Write($inner)
                    }
                }

                With-ConsoleColor $borderFg $borderBg { Set-UiCursorPosition ($x0 + $menuW - 1) $lineY; [Console]::Write("│") }
            }

            # fill remaining lines (if any)
            for ($j = 6; $j -lt ($menuH - 1); $j++) {
                $lineY = $y0 + $j
                With-ConsoleColor $borderFg $borderBg {
                    Set-UiCursorPosition $x0 $lineY; [Console]::Write("│")
                    Set-UiCursorPosition ($x0 + $menuW - 1) $lineY; [Console]::Write("│")
                }
                With-ConsoleColor ($UI_Color_InputText) $borderBg {
                    Set-UiCursorPosition ($x0 + 1) $lineY; [Console]::Write((" " * ($menuW - 2)))
                }
            }

            Write-At $x0 ($y0 + $menuH - 1) ("└" + ("─" * ($menuW - 2)) + "┘") ($UI_Color_MenuFrame)
        }

        _DrawMenu

        while ($true) {
                        if (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds $UI_ShortSleepMs
            Invoke-MenuIdleTick
            continue
            }
            $k = [Console]::ReadKey($true)


            if ($k.Key -eq [ConsoleKey]::Escape) { return $null }
            if ($k.Key -eq [ConsoleKey]::UpArrow) {
                $n = $selected
                while ($true) {
                    $n = [Math]::Max(0, $n - 1)
                    if ($n -eq $selected) { break }
                    if (_IsSelectableIndex $n) { $selected = $n; break }
                    if ($n -le 0) { break }
                }
                _DrawMenu
                continue
            }
            if ($k.Key -eq [ConsoleKey]::DownArrow) { $selected = [Math]::Min(1, $selected + 1); _DrawMenu; continue }

            if ($k.Key -eq [ConsoleKey]::Enter) {
                return [bool]$items[$selected].Value
            }
        }
    } finally {
        $script:UiOverlayActive = $prevOverlay
        try { Restore-UiAfterMenu $y0 $menuH } catch { }
    }
}

function Show-DelimiterMenu {
    $prevOverlay = $script:UiOverlayActive
    $script:UiOverlayActive = $true
    try {
        try { [Console]::CursorVisible = $false } catch { }

        $winW = [Math]::Max(44, ([Console]::WindowWidth - $script:UiOffsetX - $script:UiRightMargin))
        $winH = [Math]::Max(10, [Console]::WindowHeight)

        $title = "Playout delimiter"
        $help  = $(if ($StageOnly) { "Up/Down: move   Enter: select   Esc: cancel" } else { "Up/Down: move   Enter: apply   Esc: cancel" })

        # Current custom delimiter (if any), for display purposes.
        $curCustom = ''
        try { if ($script:Settings -and $script:Settings.ContainsKey('DelimiterCustom')) { $curCustom = [string]$script:Settings.DelimiterCustom } } catch { $curCustom = '' }
        if ($null -eq $curCustom) { $curCustom = '' }
        $curCustom = $curCustom.Trim()

        # Display is formatted in two aligned columns for readability.
        $items = @(
            @{ Key = "U241F";  Glyph = "␟";    CodeLabel = "U+241F"; Desc = "recommended" }
            @{ Key = "TAB";    Glyph = "TAB";  CodeLabel = "U+0009"; Desc = "usually safe" }
            @{ Key = "CUSTOM"; Glyph = $(if ($curCustom) { $curCustom } else { "" }); CodeLabel = "custom";  Desc = "enter custom playout delimiter" }
        )

        $menuW = [Math]::Min($winW - 4, 60)
        $menuH = [Math]::Min($winH - 6, 9)
        $x0 = [Math]::Max(0, [int](($winW - $menuW) / 2))
        $y0 = [Math]::Max(0, [int](($winH - $menuH) / 2))

        $selected = 0
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ("$($items[$i].Key)".ToUpperInvariant() -eq "$script:DelimiterKey".ToUpperInvariant()) { $selected = $i; break }
        }

        function _CopyToClipboard([string]$s) {
            if ($null -eq $s) { $s = "" }
            try {
                if (Get-Command -Name Set-Clipboard -ErrorAction SilentlyContinue) {
                    Set-Clipboard -Value $s
                    return $true
                }
            } catch { }

            # Fallback: clip.exe (available on most supported Windows versions)
            try {
                $p = Start-Process -FilePath "clip.exe" -NoNewWindow -PassThru -RedirectStandardInput "pipe" -ErrorAction Stop
                $p.StandardInput.Write($s)
                $p.StandardInput.Close()
                $p.WaitForExit()
                return ($p.ExitCode -eq 0)
            } catch { }

            # Last resort: Windows Forms clipboard (may fail if not in STA)
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue | Out-Null
                [System.Windows.Forms.Clipboard]::SetText($s)
                return $true
            } catch { }

            return $false
        }

        function _ShowToast([string]$message) {
            if ([string]::IsNullOrWhiteSpace($message)) { return }

            $msg = $message.Trim()
            while ($msg.EndsWith(".")) { $msg = $msg.Substring(0, $msg.Length - 1).TrimEnd() }

            $maxW = [Math]::Max(24, [Math]::Min($menuW - 8, 72))
            if ($msg.Length -gt ($maxW - 6)) { $msg = $msg.Substring(0, ($maxW - 9)) + "..." }

            $boxW = [Math]::Min($maxW, ($msg.Length + 6))
            $boxH = 3

            # Center horizontally within the menu.
            $bx = $x0 + [int](($menuW - $boxW) / 2)

            # Center vertically within the item list area (never on the frame lines).
            $listTopY = $y0 + 4
            $listH    = ($menuH - 5)
            $by = $listTopY + [int](($listH - $boxH) / 2)

            # Safety clamps (menu interior only).
            if ($by -lt ($y0 + 2)) { $by = $y0 + 2 }
            if ($by -gt ($y0 + $menuH - 2 - $boxH + 1)) { $by = ($y0 + $menuH - 2 - $boxH + 1) }

            # Border
            Write-At $bx $by       ("┌" + ("─" * ($boxW - 2)) + "┐") ($UI_Color_MenuFrame)
            Write-At $bx ($by + 2) ("└" + ("─" * ($boxW - 2)) + "┘") ($UI_Color_MenuFrame)

            # Message line (bright text)
            $inner = (" " + $msg.PadRight($boxW - 4) + " ")

            With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                Set-UiCursorPosition $bx ($by + 1); [Console]::Write("│")
                Set-UiCursorPosition ($bx + $boxW - 1) ($by + 1); [Console]::Write("│")
            }
            With-ConsoleColor ($UI_Color_BrightText) ($UI_Color_Background) {
                Set-UiCursorPosition ($bx + 1) ($by + 1); [Console]::Write($inner)
            }

            Start-Sleep -Milliseconds $UI_ToastDurationMs

            # Redraw the Delimiter menu to restore any covered content cleanly (same behavior as the WorkDir menu).
            try { _DrawMenu } catch { }
        }

function _PromptCustomDelimiter([string]$initialValue) {
            # Modal overlay input box.
            # Returns the entered delimiter string, or $null when cancelled (Esc) / empty (Enter).
            $boxW = [Math]::Min(68, [Math]::Max(44, $menuW - 6))
            $boxH = 5
            $bx  = $x0 + [int](($menuW - $boxW) / 2)
            $by  = $y0 + [int](($menuH - $boxH) / 2)

            $prompt = "Playout delimiter: "
            $buf = ""

            $MaxCustomDelimiterLen = 5
            $warnText  = ""
            $warnUntil = [DateTime]::MinValue
            if ($initialValue) { $buf = [string]$initialValue }
            if ($buf.Length -gt $MaxCustomDelimiterLen) {
                $buf = $buf.Substring(0, $MaxCustomDelimiterLen)
                $warnText  = "Truncated to $MaxCustomDelimiterLen chars"
                $warnUntil = (Get-Date).AddMilliseconds(900)
            }

            try { [Console]::CursorVisible = $true } catch { }

            function _DrawInputBox([string]$textToShow, [switch]$HasOverflow, [string]$WarningText) {
                Write-At $bx $by       ("┌" + ("─" * ($boxW - 2)) + "┐") ($UI_Color_MenuFrame)

                $innerWHeader = $boxW - 4
                $headerTitle = "Custom playout delimiter"
                $headerHelp  = "Enter: apply   Esc: cancel"
                if (-not [string]::IsNullOrWhiteSpace($WarningText)) { $headerHelp = $WarningText }

                $hdr = $headerTitle
                if (($headerTitle.Length + 1 + $headerHelp.Length) -le $innerWHeader) {
                    $hdr = $headerTitle.PadRight($innerWHeader - $headerHelp.Length) + $headerHelp
                }
                if ($hdr.Length -gt $innerWHeader) { $hdr = $hdr.Substring(0, $innerWHeader) }
                $hdr = $hdr.PadRight($innerWHeader)

                With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                    Set-UiCursorPosition $bx ($by + 1); [Console]::Write("│ ")
                    Set-UiCursorPosition ($bx + $boxW - 2) ($by + 1); [Console]::Write(" │")
                }
                With-ConsoleColor ($UI_Color_DimText) ($UI_Color_Background) {
                    Set-UiCursorPosition ($bx + 2) ($by + 1); [Console]::Write($hdr)
                }

                Write-At $bx ($by + 2) ("├" + ("─" * ($boxW - 2)) + "┤") ($UI_Color_MenuFrame)

                $innerW = $boxW - 4
                $shown = $textToShow
                if ($shown.Length -gt $innerW) { $shown = $shown.Substring($shown.Length - $innerW, $innerW) }
                $line = ($prompt + $shown)
                if ($line.Length -gt $innerW) { $line = $line.Substring($line.Length - $innerW, $innerW) }
                $line = $line.PadRight($innerW)

                With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                    Set-UiCursorPosition $bx ($by + 3); [Console]::Write("│ ")
                    Set-UiCursorPosition ($bx + $boxW - 2) ($by + 3); [Console]::Write(" │")
                }
                With-ConsoleColor ($UI_Color_InputText) ($UI_Color_Background) {
                    Set-UiCursorPosition ($bx + 2) ($by + 3); [Console]::Write($line)
                }

                Write-At $bx ($by + 4) ("└" + ("─" * ($boxW - 2)) + "┘") ($UI_Color_MenuFrame)

                # Cursor at end (best effort)
                $cursorX = $bx + 2 + [Math]::Min($innerW, ($prompt.Length + $shown.Length))
                if ($cursorX -ge ($bx + $boxW - 2)) { $cursorX = $bx + $boxW - 3 }
                Set-UiCursorPosition $cursorX ($by + 3)
            }

            while ($true) {
                if ($warnText -and (Get-Date) -gt $warnUntil) { $warnText = "" }
                $hasOverflow = $false
                $show = $buf
                _DrawInputBox $show -HasOverflow:$hasOverflow -WarningText:$warnText

                $k = [Console]::ReadKey($true)
                if ($k.Key -eq [ConsoleKey]::Escape) { return $null }
                if ($k.Key -eq [ConsoleKey]::Enter) {
                    $val = $buf.Trim()
                    if ([string]::IsNullOrWhiteSpace($val)) { return $null }
                    if ($val.Length -gt $MaxCustomDelimiterLen) { $val = $val.Substring(0, $MaxCustomDelimiterLen) }
                    return $val
                }

                if ($k.Key -eq [ConsoleKey]::Backspace) {
                    if ($buf.Length -gt 0) { $buf = $buf.Substring(0, $buf.Length - 1) }
                    continue
                }

                # Allow pasted text and printable characters (including spaces).
                if ($k.KeyChar -ne [char]0) {
                    if ($buf.Length -ge $MaxCustomDelimiterLen) {
                        $warnText  = "Max $MaxCustomDelimiterLen chars"
                        $warnUntil = (Get-Date).AddMilliseconds(900)
                        continue
                    }
                    $buf += [string]$k.KeyChar
                }
            }
        }
        function _DrawMenu {
            Draw-MenuFrame $x0 $y0 $menuW $title $help

            $borderFg = $UI_Color_MenuFrame
            $borderBg = [Console]::BackgroundColor

            $leftW = 0
            foreach ($it in $items) {
                $lw = ("{0}  ({1})" -f $it.Glyph, $it.CodeLabel).Length
                if ($lw -gt $leftW) { $leftW = $lw }
            }

            $listH = $menuH - 5
            for ($i = 0; $i -lt $listH; $i++) {
                $lineY = $y0 + 4 + $i
                if ($i -ge $items.Count) {
                    With-ConsoleColor $borderFg $borderBg {
                        Set-UiCursorPosition $x0 $lineY; [Console]::Write("│")
                        Set-UiCursorPosition ($x0 + $menuW - 1) $lineY; [Console]::Write("│")
                    }
                    With-ConsoleColor ($UI_Color_InputText) $borderBg {
                        Set-UiCursorPosition ($x0 + 1) $lineY; [Console]::Write((" " * ($menuW - 2)))
                    }
                    continue
                }

                                $targetParenCol = 7
                $gap = $targetParenCol - $items[$i].Glyph.Length
                if ($gap -lt 2) { $gap = 2 }

                $left = ("{0}{1}({2})" -f $items[$i].Glyph, (" " * $gap), $items[$i].CodeLabel)
$label = ($left.PadRight($leftW) + "  -  " + $items[$i].Desc)

                $text = " " + $label
                if ($text.Length -gt ($menuW - 4)) { $text = $text.Substring(0, $menuW - 4) }
                $text = $text.PadRight($menuW - 4)
                $inner = " " + $text + " "

                With-ConsoleColor $borderFg $borderBg { Set-UiCursorPosition $x0 $lineY; [Console]::Write("│") }

                if ($i -eq $selected) {
                    With-ConsoleColor ($UI_Color_SelectedText) ($UI_Color_SelectedBack) {
                        Set-UiCursorPosition ($x0 + 1) $lineY; [Console]::Write($inner)
                    }
                } else {
                    With-ConsoleColor ($UI_Color_InputText) $borderBg {
                        Set-UiCursorPosition ($x0 + 1) $lineY; [Console]::Write($inner)
                    }
                }

                With-ConsoleColor $borderFg $borderBg { Set-UiCursorPosition ($x0 + $menuW - 1) $lineY; [Console]::Write("│") }
            }

            Write-At $x0 ($y0 + $menuH - 1) ("└" + ("─" * ($menuW - 2)) + "┘") ($UI_Color_MenuFrame)
        }

        _DrawMenu

        while ($true) {
                        if (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds $UI_ShortSleepMs
            Invoke-MenuIdleTick
            continue
            }
            $k = [Console]::ReadKey($true)


            if ($k.Key -eq [ConsoleKey]::Escape) { return $false }
            if ($k.Key -eq [ConsoleKey]::UpArrow)   { $selected = [Math]::Max(0, $selected - 1); _DrawMenu; continue }
            if ($k.Key -eq [ConsoleKey]::DownArrow) { $selected = [Math]::Min($items.Count - 1, $selected + 1); _DrawMenu; continue }

            if ($k.Key -eq [ConsoleKey]::Enter) {
                $newKey = "$($items[$selected].Key)".Trim().ToUpperInvariant()
                $changed = $false

                if ($newKey -eq 'CUSTOM') {
                    $val = _PromptCustomDelimiter $curCustom
                    if ($null -eq $val) { _DrawMenu; continue }

                    # Apply to settings immediately (so Apply-DelimiterFromSettings can pick it up).
                    if (-not $script:Settings) { $script:Settings = @{} }
                    $script:Settings.DelimiterCustom = $val
                    # Keep runtime delimiter in sync so clipboard/toast reflect the entered value immediately.
                    $script:SepChar  = $val
                    $script:SepGlyph = $val

                    $changed = ($script:DelimiterKey.ToUpperInvariant() -ne 'CUSTOM') -or ($curCustom -ne $val)
                    $script:DelimiterKey = 'CUSTOM'
                } else {
                    $changed = ($newKey -ne "$script:DelimiterKey".Trim().ToUpperInvariant())
                    $script:DelimiterKey = $newKey
                }

                Save-DelimiterSetting
                Apply-DelimiterFromSettings
                try { Refresh-UiAfterSettingChange } catch { }

                # Copy to clipboard + toast (always, even when the selection didn't change).
                $clipText = [string]$script:SepChar
                $toastText = $clipText
                if ($clipText -eq "`t") { $toastText = "TAB" }
                if (_CopyToClipboard $clipText) {
                    _ShowToast ("[{0}] copied to clipboard" -f $toastText)
                } else {
                    _ShowToast ("Clipboard copy failed")
                }

                return $changed
            }
        }
    } finally {
        $script:UiOverlayActive = $prevOverlay
        try { Restore-UiAfterMenu $y0 $menuH } catch { }
    }
}

function Show-SettingsMenu {
    $prevOverlay = $script:UiOverlayActive
    $script:UiOverlayActive = $true
    $anyChanged = $false
    # Snapshot current settings so Esc can discard changes reliably.
    # We copy key/value pairs to keep the object type consistent (hashtable-like).
    $originalSettings = @{}
    foreach ($k in $script:Settings.Keys) { $originalSettings[$k] = $script:Settings[$k] }
    try {
        try { [Console]::CursorVisible = $false } catch { }

        $winW = [Math]::Max(44, ([Console]::WindowWidth - $script:UiOffsetX - $script:UiRightMargin))
        $winH = [Math]::Max(10, [Console]::WindowHeight)

        $title = "Settings"
        $help  = "Up/Down: move   Enter: open/select   Esc: cancel"

        $items = @(
            @{ Label = "Working directory";      Kind = "workdir" }
            @{ Label = "Prefix language";        Kind = "prefix" }
            @{ Label = "ASCII-safe";             Kind = "ascii" }
            @{ Label = "Transliteration EL/CYR"; Kind = "translit" }
            @{ Label = "Playout delimiter";      Kind = "sep" }
            @{ Label = "Save & exit";            Kind = "exit" }
        )

        $menuW = [Math]::Min($winW - 4, 56)
        if ($menuW -lt 50) { $menuW = [Math]::Min($winW - 4, 50) }
        $menuH = [Math]::Min($winH - 6, 12)
        $x0 = [Math]::Max(0, [int](($winW - $menuW) / 2))
        $y0 = [Math]::Max(0, [int](($winH - $menuH) / 2))

        $selected = 0

        function _IsSelectableIndex([int]$idx) {
            if ($idx -lt 0 -or $idx -ge $items.Count) { return $false }
            $k = $items[$idx].Kind
            if ($k -eq "translit" -and $script:AsciiSafeEnabled) { return $false }
            return $true
        }

        function _DrawMenu {
            Draw-MenuFrame $x0 $y0 $menuW $title $help

            $borderFg = $UI_Color_MenuFrame
            $borderBg = [Console]::BackgroundColor

            $listH = $menuH - 5
            for ($i = 0; $i -lt $listH; $i++) {
                $lineY = $y0 + 4 + $i
                $idx = $i

                if ($idx -ge $items.Count) {
                    With-ConsoleColor $borderFg $borderBg {
                        Set-UiCursorPosition $x0 $lineY
                        [Console]::Write("│")
                        Set-UiCursorPosition ($x0 + $menuW - 1) $lineY
                        [Console]::Write("│")
                    }
                    With-ConsoleColor ($UI_Color_InputText) $borderBg {
                        Set-UiCursorPosition ($x0 + 1) $lineY
                        [Console]::Write((" " * ($menuW - 2)))
                    }
                    continue
                }

                $innerW = ($menuW - 4)

                function _Ellipsize-Middle([string]$s, [int]$maxLen) {
                    if ($null -eq $s) { $s = "" }
                    if ($maxLen -le 0) { return "" }
                    if ($s.Length -le $maxLen) { return $s }
                    if ($maxLen -le 3) { return ("." * $maxLen) }

                    $keep = $maxLen - 3
                    $leftKeep  = [int][Math]::Ceiling($keep / 2.0)
                    $rightKeep = [int]($keep - $leftKeep)

                    return ($s.Substring(0, $leftKeep) + "..." + $s.Substring($s.Length - $rightKeep))
                }

                function _FormatMenuLine([string]$left, [string]$value) {
                    if ($null -eq $left)  { $left  = "" }
                    if ($null -eq $value) { $value = "" }

                    if ([string]::IsNullOrWhiteSpace($value)) {
                        $t = " " + $left
                        if ($t.Length -gt $innerW) { $t = $t.Substring(0, $innerW) }
                        return $t.PadRight($innerW)
                    }

                    $space    = 1
                    $rightPad = 1   # Keep 1 empty column to the right border (symmetry with left padding)

                    # Keep the label fully visible (with at least one space after it) by truncating the value first.
                    $maxValueLen = [Math]::Max(0, ($innerW - (1 + $left.Length) - $space - $rightPad))
                    if ($value.Length -gt $maxValueLen) {
                        $value = _Ellipsize-Middle $value $maxValueLen
                    }

                    $leftMax = [Math]::Max(0, ($innerW - $value.Length - $space - $rightPad))
                    if ($left.Length -gt $leftMax) {
                        $left = $left.Substring(0, $leftMax)
                    }

                    $t = (" " + $left.PadRight($leftMax) + (" " * $space) + $value + (" " * $rightPad))

                    if ($t.Length -gt $innerW) { $t = $t.Substring(0, $innerW) }
                    return $t.PadRight($innerW)
                }

                $kind = $items[$idx].Kind
                $leftText  = $items[$idx].Label
                $valueText = ""

                if ($kind -eq 'workdir') {
                    $wd = ""
                    try { $wd = "$($script:Settings.WorkDir)".Trim() } catch { }
                    if (-not $wd) {
                        try { $wd = (Split-Path -Parent $script:InFile) } catch { $wd = "" }
                    }
                    $valueText = "[" + $wd + "]"
                } elseif ($kind -eq 'prefix') {
                    $pc = ""
                    try { $pc = "$script:PrefixLanguageCode".Trim() } catch { }
                    if (-not $pc) { $pc = "--" }
                    $valueText = "[" + $pc + "]"
                } elseif ($kind -eq 'ascii') {
                    $leftText  = "ASCII-safe"
                    $valueText = $(if ($script:AsciiSafeEnabled) { "[ON]" } else { "[OFF]" })
                } elseif ($kind -eq 'translit') {
                    $leftText = "Transliteration EL/CYR"
                    if ($script:AsciiSafeEnabled) {
                        $valueText = "[ON*]"
                    } else {
                        $valueText = $(if ($script:TransliterationEnabled) { "[ON]" } else { "[OFF]" })
                    }
                } elseif ($kind -eq 'sep') {
                    $leftText  = "Playout delimiter"
                    $valueText = "[" + $global:SepGlyph + "]"
                }

                $text = _FormatMenuLine $leftText $valueText
                $inner = (" " + $text + " ")

                With-ConsoleColor $borderFg $borderBg {
                    Set-UiCursorPosition $x0 $lineY
                    [Console]::Write("│")
                }

                $isEnabled = $true
                if ($items[$idx].Kind -eq "translit" -and $script:AsciiSafeEnabled) { $isEnabled = $false }

                $itemFg = ($(if ($isEnabled) { $UI_Color_InputText } else { $UI_Color_DimText }))
                if ($idx -eq $selected) {
                    # Always use the normal selected text color, even when disabled.
                    With-ConsoleColor $UI_Color_SelectedText $UI_Color_SelectedBack {
                        Set-UiCursorPosition ($x0 + 1) $lineY
                        [Console]::Write($inner)
                    }
                } else {
                    With-ConsoleColor $itemFg $borderBg {
                        Set-UiCursorPosition ($x0 + 1) $lineY
                        [Console]::Write($inner)
                    }
                }

                With-ConsoleColor $borderFg $borderBg {
                    Set-UiCursorPosition ($x0 + $menuW - 1) $lineY
                    [Console]::Write("│")
                }
            }

            Write-At $x0 ($y0 + $menuH - 1) ("└" + ("─" * ($menuW - 2)) + "┘") ($UI_Color_MenuFrame)
        }

        _DrawMenu

        while ($true) {
                        if (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds $UI_ShortSleepMs
            Invoke-MenuIdleTick
            continue
            }
            $k = [Console]::ReadKey($true)

            if ($k.Key -eq [ConsoleKey]::Escape) {
                # Cancel: restore original settings and re-apply runtime state.
                $script:Settings.Clear()
                foreach ($kk in $originalSettings.Keys) { $script:Settings[$kk] = $originalSettings[$kk] }
                Save-Settings

                Load-AsciiSafeSetting
                Load-TransliterationSetting
                Load-PrefixLanguageSetting
                Apply-PrefixFromLanguage
                Apply-DelimiterFromSettings
                Apply-WorkDirIfConfigured

                try { Refresh-UiAfterSettingChange } catch { }
                try { Draw-Header } catch { }

                return $false
            }
            if ($k.Key -eq [ConsoleKey]::UpArrow)   { $selected = [Math]::Max(0, $selected - 1); _DrawMenu; continue }
            if ($k.Key -eq [ConsoleKey]::DownArrow) { $selected = [Math]::Min($items.Count - 1, $selected + 1); _DrawMenu; continue }

            if ($k.Key -eq [ConsoleKey]::Enter) {

                if (-not (_IsSelectableIndex $selected)) {
                    try { [Console]::Beep(800,120) } catch { }
                    _DrawMenu
                    continue
                }

                                $kind = $items[$selected].Kind
                if ($kind -eq 'exit') { return $anyChanged }

                $changed = $false

                if ($kind -eq 'workdir') {
                    $changed = Show-WorkDirMenu
                    if ($changed) {
                        try { Apply-WorkDirIfConfigured } catch { }
                        try { Draw-Header } catch { }
                        $script:RebuildWatcher = $true
                    }
                } elseif ($kind -eq 'prefix') {
                    $changed = Show-LanguageMenu
                } elseif ($kind -eq 'ascii') {
                    $newVal = Show-OnOffMenu "ASCII-safe" $script:AsciiSafeEnabled
                    if ($null -ne $newVal -and $newVal -ne $script:AsciiSafeEnabled) {
                        $changed = Toggle-AsciiSafe
                        if ($newVal -ne $script:AsciiSafeEnabled) { $changed = Toggle-AsciiSafe } # ensure exact state
                    }
                } elseif ($kind -eq 'translit') {
                    $newVal = Show-OnOffMenu "Transliteration EL/CYR" $script:TransliterationEnabled
                    if ($null -ne $newVal -and $newVal -ne $script:TransliterationEnabled) {
                        if ($script:AsciiSafeEnabled -and -not $newVal) {
                            $changed = $false
                        } else {
                            $changed = Toggle-Transliteration
                            if ($newVal -ne $script:TransliterationEnabled) { $changed = Toggle-Transliteration }
                        }
                    }
                } elseif ($kind -eq 'sep') {
                    $changed = Show-DelimiterMenu
                }

                if ($changed) { $anyChanged = $true }
                _DrawMenu
            }
        }
    } finally {
        $script:UiOverlayActive = $prevOverlay
        try { Restore-UiAfterMenu $y0 $menuH } catch { }
    }
}

function Show-WorkDirMenu([switch]$MarkWizardDone) {

    $prevOverlay = $script:UiOverlayActive
    $script:UiOverlayActive = $true
    try {
        # Interactive working-directory picker (arrow keys + Enter).
        # Item 1 selects the current folder, item 2 goes to parent, remaining items enter subfolders.

        $menuW = 86
        $menuH = [Math]::Max(16, [Math]::Min(22, [Console]::WindowHeight - 4))

        $x0 = [Math]::Max(0, [Math]::Floor((([Console]::WindowWidth - $script:UiOffsetX - $script:UiRightMargin) - $menuW) / 2))
        $x0 += $script:UiOffsetX
    $y0 = [Math]::Max(0, [Math]::Floor((([Console]::WindowHeight - $script:UiOffsetY) - $menuH) / 2))
    $y0 += $script:UiOffsetY

    $listLines = $null  # computed after infoLines is known
$defaultDir = ''
    try { $defaultDir = (Split-Path -Parent $script:InFile) } catch { }
    if (-not $defaultDir) { $defaultDir = $AppBaseDir }

    $currentDir = ''
    try { $currentDir = "$($script:Settings.WorkDir)".Trim() } catch { }
    if (-not $currentDir) { $currentDir = $defaultDir }
    if (-not (Test-Path -LiteralPath $currentDir)) { $currentDir = $defaultDir }
    try { $currentDir = (Resolve-Path -LiteralPath $currentDir -ErrorAction Stop).Path } catch { }

    # Info area above the list: always show a single line with the folder currently under the cursor.
    $infoLines = 1
    # Calculate list height so the frame always uses the full menu height.
    # Layout: top(4) + infoLines + sep(1) + listLines + bottom(1) = menuH
    $listLines = [Math]::Max(6, ($menuH - 6 - $infoLines))
    $listTopY = $y0 + 3 + $infoLines + 2
    $promptY  = $listTopY + $listLines - 1
    $title = "Set working directory"
    $help1 = "Up/Down: navigate   Enter: open/select   N: new folder   Esc: cancel"
    # (no second header line)
    $selectedIndex = 0
    $lastMsg = ""
    $toastPending = $false
    function _SetMsg([string]$m) {
        # NOTE: nested functions run in their own scope; update the parent variables explicitly.
        Set-Variable -Name lastMsg -Scope 1 -Value $m
        Set-Variable -Name toastPending -Scope 1 -Value (-not [string]::IsNullOrWhiteSpace($m))
        Set-Variable -Name needsRedraw  -Scope 1 -Value $true
    }

    function _FrameLine([string]$text) {
        return ("│ " + $text.PadRight($menuW - 4).Substring(0, $menuW - 4) + " │")
    }

    function _WriteFrameTextLine([int]$y, [string]$text, [ConsoleColor]$textColor) {
        $innerW = $menuW - 4
        $t = $text
        if ($null -eq $t) { $t = "" }
        if ($t.Length -gt $innerW) { $t = $t.Substring(0, $innerW) }
        $t = $t.PadRight($innerW)

        # Left border + space
        With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
            Set-UiCursorPosition $x0 $y
            [Console]::Write("│ ")
        }

        # Text (dim)
        With-ConsoleColor $textColor ($UI_Color_Background) {
            Set-UiCursorPosition ($x0 + 2) $y
            [Console]::Write($t)
        }

        # Space + right border
        With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
            Set-UiCursorPosition ($x0 + $menuW - 2) $y
            [Console]::Write(" │")
        }
    }

    function _DrawFrame([string]$CursorFolder) {
        Write-At $x0 $y0 ("┌" + ("─" * ($menuW - 2)) + "┐") ($UI_Color_MenuFrame)
        _WriteFrameTextLine ($y0 + 1) $title ($UI_Color_DimText)
        _WriteFrameTextLine ($y0 + 2) $help1 ($UI_Color_DimText)
        Write-At $x0 ($y0 + 3) ("├" + ("─" * ($menuW - 2)) + "┤") ($UI_Color_MenuFrame)

                function _WriteInfoLine([int]$y, [string]$label, [string]$value) {
            $innerW = $menuW - 4
            $labelText = ($label + " ")
            $v = $value

            # If this line ends with the informational suffix, render that suffix dim (and keep it intact
            # when truncating the path).
            $suffix = ""
            if ($v -and $v.EndsWith(" (will be created)")) {
                $suffix = " (will be created)"
                $v = $v.Substring(0, $v.Length - $suffix.Length)
            }

            $maxValueLen = [Math]::Max(0, $innerW - $labelText.Length - $suffix.Length)
            if ($v.Length -gt $maxValueLen) {
                $keep = [Math]::Max(0, $maxValueLen - 3)
                if ($keep -gt 0) { $v = $v.Substring(0, $keep) + "..." } else { $v = "..." }
            }

            # Left border
            With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                Set-UiCursorPosition $x0 $y
                [Console]::Write("│ ")
            }

            # Label (dim)
            With-ConsoleColor ($UI_Color_DimText) ($UI_Color_Background) {
                Set-UiCursorPosition ($x0 + 2) $y
                [Console]::Write($labelText)
            }

            # Value (normal)
            With-ConsoleColor ($UI_Color_InputText) ($UI_Color_Background) {
                Set-UiCursorPosition ($x0 + 2 + $labelText.Length) $y
                [Console]::Write($v)
            }

            # Suffix (dim)
            if ($suffix) {
                With-ConsoleColor ($UI_Color_DimText) ($UI_Color_Background) {
                    Set-UiCursorPosition ($x0 + 2 + $labelText.Length + $v.Length) $y
                    [Console]::Write($suffix)
                }
            }

            # Fill remainder + right border
            $written = $labelText.Length + $v.Length + $suffix.Length
            $pad = [Math]::Max(0, $innerW - $written)
            With-ConsoleColor ($UI_Color_InputText) ($UI_Color_Background) {
                Set-UiCursorPosition ($x0 + 2 + $written) $y
                [Console]::Write((" " * $pad))
            }
            With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                Set-UiCursorPosition ($x0 + $menuW - 2) $y
                [Console]::Write(" │")
            }
        }

        # Info line (always present): show the folder path that is currently under the cursor.
        _WriteInfoLine ($y0 + 4) "Current folder:" $CursorFolder

        Write-At $x0 ($listTopY - 1) ("├" + ("─" * ($menuW - 2)) + "┤") ($UI_Color_MenuFrame)

# List area
for ($i = 0; $i -lt $listLines; $i++) {
    Write-At $x0 ($listTopY + $i) (_FrameLine "") ($UI_Color_MenuFrame)
}

Write-At $x0 ($listTopY + $listLines) ("└" + ("─" * ($menuW - 2)) + "┘") ($UI_Color_MenuFrame)
    }

    function _GetItems {
        $items = New-Object System.Collections.Generic.List[string]

        # Virtual helper entry (first item when shown):
        # If the configured folder from settings does not exist anymore) offer that path for explicit creation.
        # Otherwise (first-run, offer creation of the default folder (derived from the input file location).
        $createTarget = $null
        try {
            $cfg = "$($script:Settings.WorkDir)".Trim()
            if ($cfg -and -not (Test-Path -LiteralPath $cfg)) { $createTarget = $cfg }
        } catch { }

        if (-not $createTarget) {
            try { if (-not (Test-Path -LiteralPath $defaultDir)) { $createTarget = $defaultDir } } catch { }
        }

        if ($createTarget) {
            if ($createTarget -eq $defaultDir) {
                [void]$items.Add("[Create default folder: $createTarget]")
            } else {
                [void]$items.Add("[Create folder: $createTarget]")
            }
        }

        [void]$items.Add("[Select this folder]")

$parentPath = $null
try { $parentPath = Split-Path -Path $currentDir -Parent } catch { $parentPath = $null }
if (-not [string]::IsNullOrWhiteSpace($parentPath) -and ($parentPath -ne $currentDir) -and (Test-Path -LiteralPath $parentPath)) {
    [void]$items.Add("..  (Parent)")
}

        $dirs = @()
        try {
            $dirs = Get-ChildItem -LiteralPath $currentDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name
        } catch { $dirs = @() }

        foreach ($d in $dirs) {
            # keep only the leaf name in the list
            [void]$items.Add($d.Name)
        }
        return ,$items
    }

    function _IsDirWritable([string]$path) {
        try {
            if ([string]::IsNullOrWhiteSpace($path)) { return $false }
            if (-not (Test-Path -LiteralPath $path)) { return $false }

            $name = [System.IO.Path]::GetRandomFileName()
            $tmp  = Join-Path $path (".__writetest_" + $name)

            # Create with CreateNew to avoid clobbering anything.
            $fs = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $fs.Close()
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue | Out-Null
            return $true
        } catch {
            try { if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue | Out-Null } } catch { }
            return $false
        }
    }

    function _ShowToast([string]$message) {
        if ([string]::IsNullOrWhiteSpace($message)) { return }

        $msg = $message.Trim()
        while ($msg.EndsWith(".")) { $msg = $msg.Substring(0, $msg.Length - 1).TrimEnd() }
        $maxW = [Math]::Max(24, [Math]::Min($menuW - 8, 72))
        if ($msg.Length -gt ($maxW - 6)) { $msg = $msg.Substring(0, ($maxW - 9)) + "..." }

        $boxW = [Math]::Min($maxW, ($msg.Length + 6))
        $boxH = 3
        $bx = $x0 + [int](($menuW - $boxW) / 2)
        $by = $y0 + [int](($menuH - $boxH) / 2)
        if ($by -lt ($y0 + 4)) { $by = $y0 + 4 }

        # Border
        Write-At $bx $by       ("┌" + ("─" * ($boxW - 2)) + "┐") ($UI_Color_MenuFrame)
        Write-At $bx ($by + 2) ("└" + ("─" * ($boxW - 2)) + "┘") ($UI_Color_MenuFrame)

        # Message line (white, centered within the box)
        $inner = (" " + $msg.PadRight($boxW - 4) + " ")

        With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
            Set-UiCursorPosition $bx ($by + 1)
            [Console]::Write("│")
        }

        With-ConsoleColor ($UI_Color_BrightText) ($UI_Color_Background) {
            Set-UiCursorPosition ($bx + 1) ($by + 1)
            [Console]::Write($inner)
        }

        With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
            Set-UiCursorPosition ($bx + $boxW - 1) ($by + 1)
            [Console]::Write("│")
        }

        Start-Sleep -Milliseconds $UI_ToastDurationMs

        # Redraw the full WorkDir UI so the list never ends up blank after the toast disappears.
        try {
            $items = _GetItems
            $cursorFolder = _GetCursorFolderDisplay $items $selectedIndex
            _DrawFrame $cursorFolder
            _DrawList $items
        } catch { }
    }

function _DrawList([System.Collections.Generic.List[string]]$items) {
        $innerW = $menuW - 4
        $visible = $listLines

        if ($selectedIndex -lt 0) { $selectedIndex = 0 }
        if ($selectedIndex -gt ($items.Count - 1)) { $selectedIndex = [Math]::Max(0, $items.Count - 1) }

        $top = 0
        if ($selectedIndex -ge $visible) { $top = $selectedIndex - ($visible - 1) }
        if ($top -gt [Math]::Max(0, $items.Count - $visible)) { $top = [Math]::Max(0, $items.Count - $visible) }

        for ($row = 0; $row -lt $visible; $row++) {
            $idx = $top + $row
            $text = ""
            if ($idx -lt $items.Count) { $text = $items[$idx] }

            if ($text.Length -gt $innerW) { $text = $text.Substring(0, $innerW - 3) + "..." }
            $line = $text.PadRight($innerW)

            $fg = $UI_Color_InputText
            $bg = $UI_Color_Background
            if ($idx -eq $selectedIndex) {
                $fg = $UI_Color_SelectedText
                $bg = $UI_Color_SelectedBack
            }

            With-ConsoleColor $fg $bg {
                # The list top differs depending on whether the "Current" line is present.
                # Use the computed $listTopY instead of a hard-coded offset.
                Set-UiCursorPosition ($x0 + 2) ($listTopY + $row)
                [Console]::Write($line)
            }
        }

        if ($toastPending -and -not [string]::IsNullOrEmpty($lastMsg)) {
            $m = $lastMsg

            # NOTE: nested functions have their own scope; clear the parent variables explicitly
            # so the toast cannot be re-triggered by subsequent redraws (e.g. on Up/Down).
            Set-Variable -Name lastMsg -Scope 1 -Value ""
            Set-Variable -Name toastPending -Scope 1 -Value $false

            _ShowToast $m
        }
    }

    function _PromptNewFolderName {
        # Modal overlay input box.
        # Returns the entered folder name, or $null when cancelled (Esc) / empty (Enter).
        $boxW = [Math]::Min(60, [Math]::Max(38, $menuW - 10))
        $boxH = 5
        $bx  = $x0 + [int](($menuW - $boxW) / 2)
        $by  = $y0 + [int](($menuH - $boxH) / 2)

        $prompt = "Name: "
        $buf = ""

        try { [Console]::CursorVisible = $true } catch { }

        function _DrawInputBox([string]$textToShow, [switch]$HasOverflow) {
            Write-At $bx $by       ("┌" + ("─" * ($boxW - 2)) + "┐") ($UI_Color_MenuFrame)
            # Header line (dim text), with the help text right-aligned on the same line.
            $innerWHeader = $boxW - 4
            $headerTitle = "Create new folder"
            $headerHelp  = "Enter: create   Esc: cancel"

            $hdr = $headerTitle
            if (($headerTitle.Length + 1 + $headerHelp.Length) -le $innerWHeader) {
                $hdr = $headerTitle.PadRight($innerWHeader - $headerHelp.Length) + $headerHelp
            }
            if ($hdr.Length -gt $innerWHeader) { $hdr = $hdr.Substring(0, $innerWHeader) }
            $hdr = $hdr.PadRight($innerWHeader)

            With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                Set-UiCursorPosition $bx ($by + 1)
                [Console]::Write("│ ")
            }
            With-ConsoleColor ($UI_Color_DimText) ($UI_Color_Background) {
                Set-UiCursorPosition ($bx + 2) ($by + 1)
                [Console]::Write($hdr)
            }
            With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                Set-UiCursorPosition ($bx + $boxW - 2) ($by + 1)
                [Console]::Write(" │")
            }

            Write-At $bx ($by + 2) ("├" + ("─" * ($boxW - 2)) + "┤") ($UI_Color_MenuFrame)

            # Content line (inside the box)
            $innerW = $boxW - 4
            $content = $textToShow
            if ($content.Length -gt $innerW) { $content = $content.Substring(0, $innerW) }
            $content = $content.PadRight($innerW)

            # Left border
            With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                Set-UiCursorPosition $bx ($by + 3)
                [Console]::Write("│ ")
            }

            if ($HasOverflow) {
                With-ConsoleColor ($UI_Color_InputText) ($UI_Color_Background) {
                    Set-UiCursorPosition ($bx + 2) ($by + 3)
                    [Console]::Write($content)
                }
            } else {
                With-ConsoleColor ($UI_Color_DimText) ($UI_Color_Background) {
                    Set-UiCursorPosition ($bx + 2) ($by + 3)
                    [Console]::Write($prompt)
                }
                With-ConsoleColor ($UI_Color_InputText) ($UI_Color_Background) {
                    Set-UiCursorPosition ($bx + 2 + $prompt.Length) ($by + 3)
                    [Console]::Write(($content.Substring($prompt.Length)))
                }
            }

            With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
                Set-UiCursorPosition ($bx + $boxW - 2) ($by + 3)
                [Console]::Write(" │")
            }

            Write-At $bx ($by + 4) ("└" + ("─" * ($boxW - 2)) + "┘") ($UI_Color_MenuFrame)
        }

        while ($true) {
            $full = $prompt + $buf
            $overflow = $false
            $toShow = $full

            $innerW = $boxW - 4
            if ($toShow.Length -gt $innerW) {
                $toShow = "..." + $toShow.Substring($toShow.Length - ($innerW - 3))
                $overflow = $true
            }

            _DrawInputBox $toShow -HasOverflow:($overflow)

            # Best-effort cursor placement in the input line
            $cursorX = $bx + 2 + [Math]::Min(($innerW - 1), ($prompt + $buf).Length)
            $cursorY = $by + 3
            try { Set-UiCursorPosition $cursorX $cursorY } catch { }

                        if (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds $UI_ShortSleepMs
            Invoke-MenuIdleTick
            continue
            }
            $k = [Console]::ReadKey($true)


            if ($k.Key -eq [ConsoleKey]::Escape) {
                try { [Console]::CursorVisible = $false } catch { }
                return $null
            }

            if ($k.Key -eq [ConsoleKey]::Enter) {
                try { [Console]::CursorVisible = $false } catch { }
                $name = $buf.Trim()
                if (-not $name) { return $null }
                return $name
            }

            if ($k.Key -eq [ConsoleKey]::Backspace) {
                if ($buf.Length -gt 0) { $buf = $buf.Substring(0, $buf.Length - 1) }
                continue
            }

            # Append printable characters only
            if ($k.KeyChar -and -not [char]::IsControl($k.KeyChar)) {
                $buf += [string]$k.KeyChar
            }
        }
    }

    function _GetCursorFolderDisplay($items, [int]$idx) {
        try {
            if ($null -eq $items -or $items.Count -le 0) {
                return $currentDir
            }

            if ($idx -lt 0) { $idx = 0 }
            if ($idx -gt ($items.Count - 1)) { $idx = $items.Count - 1 }

            $choice = $items[$idx]

            if (($choice -match '^\[Select.*\]$') -and ($choice -match 'folder')) {
                # Cursor is on the "select current directory" entry
                return $currentDir
            }

            if ($choice -match '^\[Create .*folder:\s*(.+)\]$') {
                # Cursor is on the virtual "Create ..." entry: keep showing the real current directory.
                return $currentDir
            }

            if ($choice -like "..*") {
                try { return (Split-Path -Path $currentDir -Parent) } catch { return $currentDir }
            }

            # Regular directory entry
            return (Join-Path $currentDir $choice)
        } catch {
            return $currentDir
        }
    }

    $items = _GetItems
    $cursorFolder = _GetCursorFolderDisplay $items $selectedIndex
    _DrawFrame $cursorFolder

        $needsRedraw = $true

    while ($true) {

        if ($needsRedraw) {
            $items = _GetItems
            if ($selectedIndex -gt ($items.Count - 1)) { $selectedIndex = [Math]::Max(0, $items.Count - 1) }
            if ($selectedIndex -lt 0) { $selectedIndex = 0 }

            $cursorFolder = _GetCursorFolderDisplay $items $selectedIndex
            _DrawFrame $cursorFolder
            _DrawList $items

            $needsRedraw = $false
        }

                if (-not [Console]::KeyAvailable) {
        Start-Sleep -Milliseconds $UI_ShortSleepMs
        Invoke-MenuIdleTick
        continue
        }
        $k = [Console]::ReadKey($true)


        if ($k.Key -eq [ConsoleKey]::Escape) {
            try { Restore-UiAfterMenu $y0 $menuH } catch { }
            return $false
        }

        if ($k.Key -eq [ConsoleKey]::UpArrow) {
            $selectedIndex--
            if ($selectedIndex -lt 0) { $selectedIndex = 0 }
            $needsRedraw = $true
            continue
        }

        if ($k.Key -eq [ConsoleKey]::DownArrow) {
            $selectedIndex++
            if ($selectedIndex -gt ($items.Count - 1)) { $selectedIndex = [Math]::Max(0, $items.Count - 1) }
            $needsRedraw = $true
            continue
        }

        if ($k.Key -eq [ConsoleKey]::N) {

            $name = _PromptNewFolderName
            if ($null -eq $name) { $lastMsg = ""; $toastPending = $false; continue }

            # Validate folder name (Windows rules)
            $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
            if ($name.IndexOfAny($invalidChars) -ge 0) {
                _SetMsg "Invalid folder name"
                continue
            }
            if ($name -match '^\.+$') {
                _SetMsg "Invalid folder name"
                continue
            }

            $target = Join-Path $currentDir $name

            if (Test-Path -LiteralPath $target) {
                _SetMsg "Folder already exists"
                continue
            }

            try {
                New-Item -ItemType Directory -Path $target -ErrorAction Stop | Out-Null
                try { $target = (Resolve-Path -LiteralPath $target -ErrorAction Stop).Path } catch { }
                $currentDir = $target
                $selectedIndex = 0
                _SetMsg "Folder created"
                        $needsRedraw = $true
            } catch {
                _SetMsg "Unable to create folder"
            }

            continue
        }

        if ($k.Key -eq [ConsoleKey]::Enter) {

            if ($items.Count -le 0) { continue }

            $choice = $items[$selectedIndex]

            if ($choice -match '^\[Create\s+.*folder:\s*.+\]$') {

                $picked = $null
                try {
                    $p = $choice.Trim().TrimStart('[').TrimEnd(']')
                    $picked = ($p -split "folder:\s*", 2)[1].Trim()
                } catch { $picked = $null }

                if ([string]::IsNullOrWhiteSpace($picked)) {
                    _SetMsg "Invalid folder"
                    continue
                }

                # Explicit action: try to create the selected folder.
                if (-not (Test-Path -LiteralPath $picked)) {
                    try {
                        New-Item -ItemType Directory -Path $picked -Force -ErrorAction Stop | Out-Null
                    } catch {
                        _SetMsg "Unable to create folder"
                        continue
                    }
                }

                try { $picked = (Resolve-Path -LiteralPath $picked -ErrorAction Stop).Path } catch { }

                if (-not (_IsDirWritable $picked)) {
                    _SetMsg "Folder not writable"
                    continue
                }

                $changed = ("$($script:Settings.WorkDir)".Trim() -ne $picked)

                $script:Settings.WorkDir = $picked
                if ($MarkWizardDone) { $script:Settings.WorkDirWizardDone = $true }
                Save-Settings
                Apply-WorkDirIfConfigured

                try { Refresh-UiAfterSettingChange } catch { }
                try { Restore-UiAfterMenu $y0 $menuH } catch { }

                return $changed
            }

if (($choice -match '^\[Select.*\]$') -and ($choice -match 'folder')) {

                $picked = $currentDir
                if (-not $picked) { $picked = $defaultDir }
                if (-not (Test-Path -LiteralPath $picked)) {
                    # Do not create directories implicitly. Creation must be an explicit action via the
                    # dedicated "[Create ... folder: ...]" entry in the list.
                    _SetMsg "Folder does not exist"
                    continue
                }

try { $picked = (Resolve-Path -LiteralPath $picked -ErrorAction Stop).Path } catch { }

                if (-not (_IsDirWritable $picked)) {
                    _SetMsg "Folder not writable"
                    continue
                }

                $changed = ("$($script:Settings.WorkDir)".Trim() -ne $picked)

                $script:Settings.WorkDir = $picked
                if ($MarkWizardDone) { $script:Settings.WorkDirWizardDone = $true }
                Save-Settings
                Apply-WorkDirIfConfigured

                try { Refresh-UiAfterSettingChange } catch { }
                try { Restore-UiAfterMenu $y0 $menuH } catch { }

                return $changed
            }

            if ($choice -like "..*") {
                try {
                    $parentPath = $null
                    try { $parentPath = Split-Path -Path $currentDir -Parent } catch { $parentPath = $null }
                    if (-not [string]::IsNullOrWhiteSpace($parentPath) -and ($parentPath -ne $currentDir) -and (Test-Path -LiteralPath $parentPath)) {
                        $currentDir = $parentPath
                        $selectedIndex = 0
                        $lastMsg = ""
                        $needsRedraw = $true
                    }
                } catch {
                    _SetMsg "Unable to open parent folder"
                }
                continue
            }

            # Enter a child directory
            $target = Join-Path $currentDir $choice
            if (Test-Path -LiteralPath $target) {
                try { $target = (Resolve-Path -LiteralPath $target -ErrorAction Stop).Path } catch { }
                $currentDir = $target
                $selectedIndex = 0
                $lastMsg = ""
                        $needsRedraw = $true
            } else {
                _SetMsg "Folder not found"
            }
            continue
        }
    }
    } finally {
        $script:UiOverlayActive = $prevOverlay
    }
}

function Restore-UiAfterMenu([int]$menuTop, [int]$menuHeight) {
    # Clear only the area that was covered by the overlay menu, then redraw the underlying UI sections
    # that can be affected. This avoids a full Clear-Host redraw when leaving the menu via ESC.
    # While an overlay menu is active, Ensure-UiFresh() early-returns. Submenus can still clear parts
    # of the underlying UI (e.g. the heartbeat/legend rows), so temporarily drop the overlay flag
    # while restoring the underlay.
    $prevOverlay = $script:UiOverlayActive
    $script:UiOverlayActive = $false
    try { Ensure-UiFresh } catch { }

    try {

    $yStart = [Math]::Max(0, $menuTop)
    $yEnd   = [Math]::Max($yStart, $menuTop + $menuHeight - 1)

    for ($y = $yStart; $y -le $yEnd; $y++) {
        Write-At 0 $y "" $script:BaseFg $true
    }

    # If the menu ever overlaps the header area (small window heights), redraw the header.
    if ($yStart -lt $script:StatusTop) {
        try { Draw-Header } catch { }
    }

    # Redraw the status frame separators and the live lines that may have been covered.
    try { Draw-StatusFrame } catch { }

    $tsPart  = ""
    if ($script:LastInLine -match "^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]\s") { $tsPart = $matches[0] }
    $sepPart = ": "

    $labIn = "INPUT       "
    $labPx = "PREFIX OUT  "
    $labRt = "OUTPUT RT   "
    $labRp = "OUTPUT RT+  "

    $inVal = ""
    if (-not [string]::IsNullOrEmpty($script:LastInLine) -and ($script:LastInLine -match "^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]\s+.+?\s+:\s*(.*)$")) { $inVal = $matches[1] }

    $pxVal = ""
    if (-not [string]::IsNullOrEmpty($script:LastPxLine) -and ($script:LastPxLine -match "^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]\s+.+?\s+:\s*(.*)$")) { $pxVal = $matches[1] }

    $rtVal = ""
    if (-not [string]::IsNullOrEmpty($script:LastOutRtLine) -and ($script:LastOutRtLine -match "^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]\s+.+?\s+:\s*(.*)$")) { $rtVal = $matches[1] }

    $rpVal = ""
    if (-not [string]::IsNullOrEmpty($script:LastOutRpLine) -and ($script:LastOutRpLine -match "^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]\s+.+?\s+:\s*(.*)$")) { $rpVal = $matches[1] }

    if (-not [string]::IsNullOrEmpty($script:LastInLine))    { try { Write-SegmentedLine 0 ($script:StatusTop + 1) $tsPart $script:BaseFg $labIn $script:LastInFg $sepPart $script:BaseFg $inVal   $script:LastInFg $true } catch { } }
    if (-not [string]::IsNullOrEmpty($script:LastPxLine))    { try { Write-SegmentedLine 0 ($script:StatusTop + 2) $tsPart $script:BaseFg $labPx $script:LastPxFg $sepPart $script:BaseFg $pxVal  $script:LastPxFg $true } catch { } }
    if (-not [string]::IsNullOrEmpty($script:LastOutRtLine)) { try { Write-SegmentedLine 0 ($script:StatusTop + 3) $tsPart $script:BaseFg $labRt $script:LastRtFg $sepPart $script:BaseFg $rtVal     $script:LastRtFg $true } catch { } }
    if (-not [string]::IsNullOrEmpty($script:LastOutRpLine)) { try { Write-SegmentedLine 0 ($script:StatusTop + 4) $tsPart $script:BaseFg $labRp $script:LastRpFg $sepPart $script:BaseFg $rpVal $script:LastRpFg $true } catch { } }

    $script:HeartbeatLayoutValid = $false

    try { Ensure-HeartbeatLayout } catch { }
    try { Update-HeartbeatBar } catch { }
    } finally {
        $script:UiOverlayActive = $prevOverlay
    }
}

function Invoke-MenuIdleTick {
    # Keep file watching and output publishing active while an overlay menu is open.
    # UI updates are suppressed automatically while $script:UiOverlayActive is $true.
    try { Do-UpdateIfNeeded } catch { }
}

function Toggle-AsciiSafe {
    $script:AsciiSafeEnabled = -not $script:AsciiSafeEnabled
    Save-AsciiSafeSetting

    # If ASCII-safe is enabled while transliteration is OFF, temporarily force transliteration ON
    # to avoid dropping Greek/Cyrillic content entirely.
    if ($script:AsciiSafeEnabled) {
        if (-not $script:TransliterationEnabled) {
            $script:TranslitPrevBeforeAsciiSafe = $false
            $script:TransliterationEnabled = $true
            $script:TranslitForcedByAsciiSafe = $true
            Save-TransliterationSetting
        }
    } else {
        # When ASCII-safe is turned OFF, restore the previous transliteration state if we forced it.
        if ($script:TranslitForcedByAsciiSafe) {
            $script:TransliterationEnabled = $script:TranslitPrevBeforeAsciiSafe
            $script:TranslitForcedByAsciiSafe = $false
            Save-TransliterationSetting
        }
    }

    try { Refresh-UiAfterSettingChange } catch { }
    return $true
}

function Toggle-Transliteration {
    # If ASCII-safe is enabled, transliteration must remain effectively ON.
    if ($script:AsciiSafeEnabled) { return $false }

    $script:TranslitForcedByAsciiSafe = $false
    $script:TranslitPrevBeforeAsciiSafe = $script:TransliterationEnabled

    $script:TransliterationEnabled = -not $script:TransliterationEnabled
    Save-TransliterationSetting
    try { Refresh-UiAfterSettingChange } catch { }
    return $true
}

function Handle-Hotkeys {
    if (-not [Console]::KeyAvailable) { return $false }

    $k = [Console]::ReadKey($true)

    # Block Ctrl+A (Select All) where possible. Some hosts (e.g., Windows Terminal) may intercept it before we can see it.
    if ($k.Key -eq [ConsoleKey]::A -and ($k.Modifiers -band [ConsoleModifiers]::Control)) { return $true }

# Settings menu: F10 / Ctrl+S
if ($k.Key -eq [ConsoleKey]::F10 -or ($k.Key -eq [ConsoleKey]::S -and ($k.Modifiers -band [ConsoleModifiers]::Control))) {
    $changed = Show-SettingsMenu
    if ($changed) {
        try { Apply-WorkDirIfConfigured } catch { }
        $script:RebuildWatcher = $true
    }

    # IMPORTANT: When the input is currently in a warning state (Expired / NotAvailable),
    # do NOT trigger an immediate Do-Update() on menu exit. That would:
    # - re-read the stale/absent input,
    # - mark it as "fresh seen",
    # - reset the last-update timer,
    # - and clear the warning colors prematurely.
    #
    # Instead, keep the warning UI active until a *real* fresh input arrives.
    try {
        $stateNow = Get-InputUiState
        if ($changed -and $stateNow -ne "Normal") { return $false }
    } catch { }

    return $changed
}
return $false
}

function Get-UiWidth([int]$minWidth = 20) {
    # Use the *visible* console width to avoid unintended line wrapping that can overwrite UI separators.
    # Prefer WindowWidth (what the user sees), but never exceed BufferWidth.
    $ww = -1
    $bw = -1
    try { $ww = [Console]::WindowWidth } catch { }
    try { $bw = [Console]::BufferWidth } catch { }

    $w = -1
    if ($ww -gt 0 -and $bw -gt 0) { $w = [Math]::Min($ww, $bw) }
    elseif ($ww -gt 0)            { $w = $ww }
    elseif ($bw -gt 0)            { $w = $bw }
    else                          { $w = $minWidth }

    $wEff = $w - $script:UiOffsetX - $script:UiRightMargin
    return [Math]::Max($minWidth, $wEff)
}

function Set-UiCursorPosition([int]$x, [int]$y) {
    # UI-space cursor positioning (respects requested margins).
    # NOTE: $x/$y are in UI coordinates (0,0 is top-left inside the margins).
    try {
        [Console]::SetCursorPosition($x + $script:UiOffsetX, $y + $script:UiOffsetY)
    } catch { }
}

function Write-At([int]$x, [int]$y, [string]$text, [ConsoleColor]$fg, [bool]$PadLine = $true) {
    $w = Get-UiWidth 40
    $max = [Math]::Max(0, $w - $x - 1)

    $t = Pad-OrEllipsize $text $max

    if ($PadLine -and $x -eq 0 -and $max -gt 0) { $t = $t.PadRight($max) }

    try {
        With-ConsoleColor $fg ([Console]::BackgroundColor) {
            Set-UiCursorPosition $x $y
            [Console]::Write($t)
        }
    } catch { }
    try { [Console]::CursorVisible = $false } catch { }
}

function Write-SegmentedLine([int]$x, [int]$y, [string]$aText, [ConsoleColor]$aFg, [string]$bText, [ConsoleColor]$bFg, [string]$cText, [ConsoleColor]$cFg, [string]$dText, [ConsoleColor]$dFg, [bool]$PadLine = $true) {
    $w = Get-UiWidth 40
    $max = [Math]::Max(0, $w - $x - 1)

    # Clear the full line region first to avoid remnants when content shrinks.
    if ($PadLine) { try { Write-At $x $y "" $script:BaseFg $true } catch { } }

    $prefix = [string]$aText + [string]$bText + [string]$cText
    $prefixLen = $prefix.Length

    $remain = [Math]::Max(0, $max - $prefixLen)
    $d = Pad-OrEllipsize ([string]$dText) $remain

    try { Write-At $x $y ([string]$aText) $aFg $false } catch { }
    $x2 = $x + ([string]$aText).Length
    try { Write-At $x2 $y ([string]$bText) $bFg $false } catch { }
    $x3 = $x2 + ([string]$bText).Length
    try { Write-At $x3 $y ([string]$cText) $cFg $false } catch { }
    $x4 = $x3 + ([string]$cText).Length
    try { Write-At $x4 $y $d $dFg $false } catch { }

    if ($PadLine) {
        $written = $prefixLen + $d.Length
        $pad = [Math]::Max(0, $max - $written)
        if ($pad -gt 0) {
            try { Write-At ($x + $written) $y (" " * $pad) $script:BaseFg $false } catch { }
        }
    }
}

function Write-AtSegments([int]$x, [int]$y, [object[]]$segments, [ConsoleColor]$defaultFg, [bool]$PadLine = $true) {
    $w = Get-UiWidth 40
    $max = [Math]::Max(0, $w - $x - 1)

    function Get-SegText($seg) {
        if ($null -eq $seg) { return "" }
        if ($seg -is [System.Collections.IDictionary]) { return [string]($seg["Text"]) }
        return [string]($seg.Text)
    }

    function Get-SegFg($seg, [ConsoleColor]$fallback) {
        if ($null -eq $seg) { return $fallback }
        if ($seg -is [System.Collections.IDictionary]) {
            if ($seg.Contains("Fg") -and $null -ne $seg["Fg"]) { return [ConsoleColor]$seg["Fg"] }
            return $fallback
        }
        if ($null -ne $seg.Fg) { return [ConsoleColor]$seg.Fg }
        return $fallback
    }

    # Build a plain-text preview for length limiting.
    $plain = ""
    foreach ($s in $segments) { $plain += (Get-SegText $s) }

    $plain = Pad-OrEllipsize $plain $max
    if ($PadLine -and $x -eq 0 -and $max -gt 0) { $plain = $plain.PadRight($max) }

    try {
        Set-UiCursorPosition $x $y

        $pos = 0
        foreach ($s in $segments) {
            if ($pos -ge $plain.Length) { break }
            $segText = Get-SegText $s
            if ([string]::IsNullOrEmpty($segText)) { continue }

            $remaining = $plain.Length - $pos
            if ($remaining -le 0) { break }
            if ($segText.Length -gt $remaining) { $segText = $segText.Substring(0, $remaining) }

            $fg = Get-SegFg $s $defaultFg
            With-ConsoleColor $fg ([Console]::BackgroundColor) {
                [Console]::Write($segText)
            }

            $pos += $segText.Length
        }

        # Fill any remaining part of the line with spaces.
        $remainingFill = $plain.Length - $pos
        if ($remainingFill -gt 0) {
            With-ConsoleColor $defaultFg ([Console]::BackgroundColor) {
                [Console]::Write((" " * $remainingFill))
            }
        }
    } catch { }

    try { [Console]::CursorVisible = $false } catch { }
}

# -------------------- Console layout -----------------------------------------

$script:UiInited = $false
$script:UiOverlayActive = $false
$script:HeaderTop = 0

$script:HeaderLineCount = 7
$script:StatusLineCount = 12

$script:StatusTop = $script:HeaderTop + $script:HeaderLineCount
$script:LastGoodUpdate = Get-Date

# Heartbeat layout (fixed template + field updates to avoid wrap/overdraw artifacts).
$script:HeartbeatLayoutValid = $false
$script:HeartbeatLayoutWidth = -1
$script:LastHeartbeatClock = ""
$script:LastHeartbeatElapsed = ""
$script:LastHeartbeatElapsedFg = $script:BaseFg

$script:LastConsoleW = -1
$script:LastConsoleH = -1

$script:LastInLine = ""
$script:LastPxLine = ""
$script:LastOutRtLine = ""
$script:LastOutRpLine = ""
$script:LastInFg = $script:BaseFg
$script:LastPxFg = $script:BaseFg
$script:LastRtFg = $script:BaseFg
$script:LastRpFg = $script:BaseFg

$script:LastRawInput    = ""
$script:LastPrefixOut   = ""
$script:LastRtText      = ""
$script:LastRtPlusText  = ""
$script:LastRawInputShown   = ""
$script:LastPrefixOutShown  = ""
$script:LastRtTextShown     = ""
$script:LastRtPlusTextShown = ""
$script:LastInputUiState = ""

$script:HeaderWarnActive = $false

$script:LastMetadataValid = $false
function Redraw-Ui {
    try { Clear-Host } catch { }
    try { [Console]::CursorVisible = $false } catch { }

    $script:UiInited = $false
    Ensure-UiFresh

    if (-not [string]::IsNullOrEmpty($script:LastInLine))   { Write-At 0 ($script:StatusTop + 1) $script:LastInLine $script:LastInFg $true }
    if (-not [string]::IsNullOrEmpty($script:LastPxLine))   { Write-At 0 ($script:StatusTop + 2) $script:LastPxLine $script:LastPxFg $true }
    if (-not [string]::IsNullOrEmpty($script:LastOutRtLine)) { Write-At 0 ($script:StatusTop + 3) $script:LastOutRtLine $script:LastRtFg $true }
    if (-not [string]::IsNullOrEmpty($script:LastOutRpLine)) { Write-At 0 ($script:StatusTop + 4) $script:LastOutRpLine $script:LastRpFg $true }
}

function Write-MenuHeaderLine([int]$x0, [int]$y, [int]$menuW, [string]$text) {
    $innerW = $menuW - 4
    $t = $text
    if ($null -eq $t) { $t = "" }
    if ($t.Length -gt $innerW) { $t = $t.Substring(0, $innerW) }
    $t = $t.PadRight($innerW)

    With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
        Set-UiCursorPosition $x0 $y
        [Console]::Write("│ ")
    }
    With-ConsoleColor ($UI_Color_DimText) ($UI_Color_Background) {
        Set-UiCursorPosition ($x0 + 2) $y
        [Console]::Write($t)
    }
    With-ConsoleColor ($UI_Color_MenuFrame) ($UI_Color_Background) {
        Set-UiCursorPosition ($x0 + $menuW - 2) $y
        [Console]::Write(" │")
    }
}

function Draw-MenuFrame([int]$x0, [int]$y0, [int]$menuW, [string]$title, [string]$help) {
    # Border and title/help lines.
    Write-At $x0 $y0 ("┌" + ("─" * ($menuW - 2)) + "┐") ($UI_Color_MenuFrame)
    Write-MenuHeaderLine $x0 ($y0 + 1) $menuW $title
    Write-MenuHeaderLine $x0 ($y0 + 2) $menuW $help
    Write-At $x0 ($y0 + 3) ("├" + ("─" * ($menuW - 2)) + "┤") ($UI_Color_MenuFrame)
}

function Refresh-UiAfterSettingChange {
    if ($script:UiOverlayActive) { return }
    # Avoid a full Clear-Host redraw for simple setting toggles.
    # Update only the settings row (and keep the heartbeat template intact).
    try { Ensure-UiFresh } catch { }
    try { Ensure-HeartbeatLayout } catch { }
    try { Render-SettingsAndLegend } catch { }
    try { Update-HeartbeatFields } catch { }
}

function Ensure-MinConsoleLayout {
    # Force black background (requested) and set a fixed window/buffer size (best-effort).
    # Goal: stable UI layout and no scrollbars (buffer == window).
    try {
        [Console]::BackgroundColor = [ConsoleColor]::Black
        Clear-Host
    } catch { }

    try {
        if ($FixedConsoleWidth  -lt 40) { $FixedConsoleWidth  = 40 }
        if ($FixedConsoleHeight -lt 20) { $FixedConsoleHeight = 20 }

        $lw = 0; $lh = 0
        try { $lw = [Console]::LargestWindowWidth } catch { }
        try { $lh = [Console]::LargestWindowHeight } catch { }

        $targetW = $FixedConsoleWidth
        $targetH = $FixedConsoleHeight
        if ($lw -gt 0) { $targetW = [Math]::Min($targetW, $lw) }
        if ($lh -gt 0) { $targetH = [Math]::Min($targetH, $lh) }

        # Important: when shrinking, set Window first (within current buffer), then buffer.
        # When growing, set Buffer first, then Window.
        $curBW = [Console]::BufferWidth
        $curBH = [Console]::BufferHeight
        $curWW = [Console]::WindowWidth
        $curWH = [Console]::WindowHeight

        if ($curWW -gt $targetW -or $curWH -gt $targetH) {
            if ($curWW -ne $targetW -and $targetW -gt 0) { [Console]::WindowWidth  = $targetW }
            if ($curWH -ne $targetH -and $targetH -gt 0) { [Console]::WindowHeight = $targetH }
        }

        if ($curBW -ne $targetW -and $targetW -gt 0) { [Console]::BufferWidth  = $targetW }
        if ($curBH -ne $targetH -and $targetH -gt 0) { [Console]::BufferHeight = $targetH }

        if ([Console]::WindowWidth  -ne $targetW -and $targetW -gt 0) { [Console]::WindowWidth  = $targetW }
        if ([Console]::WindowHeight -ne $targetH -and $targetH -gt 0) { [Console]::WindowHeight = $targetH }

        # Ensure no scrollbars (buffer == window)
        if ([Console]::BufferWidth  -ne [Console]::WindowWidth)  { [Console]::BufferWidth  = [Console]::WindowWidth }
        if ([Console]::BufferHeight -ne [Console]::WindowHeight) { [Console]::BufferHeight = [Console]::WindowHeight }

        if ([Console]::WindowTop  -ne 0) { [Console]::WindowTop  = 0 }
        if ([Console]::WindowLeft -ne 0) { [Console]::WindowLeft = 0 }
    } catch { }
}

function Ensure-UiFresh {
    if ($script:UiOverlayActive) { return }
    $w = -1
    $h = -1
    try { $w = [Console]::WindowWidth } catch { }
    try { $h = [Console]::WindowHeight } catch { }

    if (-not $script:UiInited) {
        Init-Ui
        try { $w = [Console]::WindowWidth } catch { }
        try { $h = [Console]::WindowHeight } catch { }
        $script:LastConsoleW = $w
        $script:LastConsoleH = $h
        return
    }

    if ($w -ne $script:LastConsoleW -or $h -ne $script:LastConsoleH) {
        $script:LastConsoleW = $w
        $script:LastConsoleH = $h
        Redraw-Ui
    }

    # Keep the UI anchored at the top-left so mouse-wheel/scrollbar attempts cannot move it out of view.
    # This is best-effort: Windows console scrolling cannot be fully disabled in a pure PowerShell script,
    # but regularly snapping the viewport back prevents the UI from disappearing.
    try { Lock-ConsoleScrolling } catch { }
}

function Ensure-BufferHeight([int]$minHeight) {
    try {
        if ([Console]::BufferHeight -lt $minHeight) { [Console]::BufferHeight = $minHeight }
    } catch { }
}

function Lock-ConsoleScrolling {
    # Prevent the user from scrolling the UI out of view using the mouse wheel or the scrollbar.
    # When the window is tall enough for the full UI, we keep buffer size equal to window size (no scrollback).
    # When the window is too small, we still snap back to the top-left so the UI stays anchored.
    try {
        $w = [Console]::WindowWidth
        $h = [Console]::WindowHeight
        if ($w -le 0 -or $h -le 0) { return }

        $minH = 0
        try { $minH = ($script:StatusTop + $script:StatusLineCount + 2) } catch { $minH = 0 }

        # Width: never shrink buffer sizes (shrinks can be unstable on some hosts). Only grow when needed.
        if ([Console]::BufferWidth -lt $w) { [Console]::BufferWidth = $w }

        # Height: never shrink buffer sizes. Ensure the buffer is at least large enough for the UI
        # (or at least as tall as the visible window).
        if ($minH -gt 0 -and $h -lt $minH) {
            if ([Console]::BufferHeight -lt $minH) { [Console]::BufferHeight = $minH }
        } else {
            if ([Console]::BufferHeight -lt $h) { [Console]::BufferHeight = $h }
        }

        # Snap back to the top-left of the buffer in case the user tried to scroll.
        if ([Console]::WindowTop  -ne 0) { [Console]::WindowTop  = 0 }
        if ([Console]::WindowLeft -ne 0) { [Console]::WindowLeft = 0 }
    } catch { }
}

$script:PostInitConsoleTweaksApplied = $false
$script:HardScrollLockApplied        = $false

function Lock-ConsoleScrollingHard {
    # HARD mode: remove scrollback by matching buffer size to the visible window size.
    # Only used in classic conhost sessions (Windows Terminal manages scrollback itself).
    try {
        if ($env:WT_SESSION) { return }

        $w = [Console]::WindowWidth
        $h = [Console]::WindowHeight
        if ($w -le 0 -or $h -le 0) { return }

        $minH = 0
        try { $minH = ($script:StatusTop + $script:StatusLineCount + 2) } catch { $minH = 0 }
        if ($minH -gt 0 -and $h -lt $minH) { return }  # Do not force hard lock if the UI cannot fit.

        # Put the cursor safely inside the visible window before resizing.
        try { Set-UiCursorPosition 0 0 } catch { }

        # Match buffer to window -> no scrollback/scrollbar (classic console).
        if ([Console]::BufferWidth  -ne $w) { [Console]::BufferWidth  = $w }
        if ([Console]::BufferHeight -ne $h) { [Console]::BufferHeight = $h }

        # Pin viewport.
        if ([Console]::WindowTop  -ne 0) { [Console]::WindowTop  = 0 }
        if ([Console]::WindowLeft -ne 0) { [Console]::WindowLeft = 0 }
    } catch { }
}

function Apply-PostInitConsoleTweaks {
    # Some console hosts finalize / override input modes during startup.
    # Re-apply our preferred modes after the first full UI render.
    if ($script:PostInitConsoleTweaksApplied) { return }

    try { Disable-ConsoleQuickEdit } catch { }

    # Best-effort: in classic conhost, remove scrollback so the scrollbar is gone.
    if ($EnableHardScrollLock -and -not $script:HardScrollLockApplied) {
        try {
            Lock-ConsoleScrollingHard
            $script:HardScrollLockApplied = $true
        } catch { }
    }

    $script:PostInitConsoleTweaksApplied = $true
}

function Draw-StatusFrame {
    $top = $script:StatusTop
    $w = Get-UiWidth 40
    $line = ("-" * ([Math]::Max(1, $w - 1)))

    # Top border + separator between I/O block and heartbeat.
    Write-At 0 ($top + 0) $line DarkGray $true
    Write-At 0 ($top + 5) $line DarkGray $true

    # Separator directly under the heartbeat row (above the hotkey row).
    Write-At 0 ($top + 7) $line DarkGray $true
}

function Draw-Header {
    $t0 = ("{0} - v{1}" -f $ScriptTitle, $ScriptVersion)

    Write-At 0 ($script:HeaderTop + 0) $t0 $script:BaseFg $true
    Write-At 0 ($script:HeaderTop + 1) ""  $script:BaseFg $true
    $tsA = "Monitoring "
    $tsB = "Writing to "
    $sep = ": "

    $labIn = "INPUT       "
    $labPx = "PREFIX OUT  "
    $labRt = "OUTPUT RT   "
    $labRp = "OUTPUT RT+  "

    $fgIn = if ($script:HeaderWarnActive) { $UI_Color_WarningText } else { $UI_Color_Input }
    $fgPx = if ($script:HeaderWarnActive) { $UI_Color_WarningText } else { $UI_Color_Prefix }
    $fgRt = if ($script:HeaderWarnActive) { $UI_Color_WarningText } else { $UI_Color_RT }
    $fgRp = if ($script:HeaderWarnActive) { $UI_Color_WarningText } else { $UI_Color_RTPlus }

    Write-SegmentedLine 0 ($script:HeaderTop + 2) $tsA $script:BaseFg $labIn $fgIn $sep $script:BaseFg $InFile $fgIn $true
    Write-SegmentedLine 0 ($script:HeaderTop + 3) $tsB $script:BaseFg $labPx $fgPx $sep $script:BaseFg $PrefixFile $fgPx $true
    Write-SegmentedLine 0 ($script:HeaderTop + 4) $tsB $script:BaseFg $labRt $fgRt $sep $script:BaseFg $OutFileRt $fgRt $true
    Write-SegmentedLine 0 ($script:HeaderTop + 5) $tsB $script:BaseFg $labRp $fgRp $sep $script:BaseFg $OutFileRtPlus $fgRp $true


    Write-At 0 ($script:HeaderTop + 6) ""  $script:BaseFg $true
}

function Init-Ui {
    if ($script:UiInited) { return }
    try { Ensure-MinConsoleLayout } catch { }
    $minNeeded = $script:StatusTop + $script:StatusLineCount + 2
    Ensure-BufferHeight $minNeeded

    Draw-Header
    Draw-StatusFrame

    for ($i = 1; $i -lt $script:StatusLineCount; $i++) {
        if ($i -eq 5) { continue }
        Write-At 0 ($script:StatusTop + $i) "" $script:BaseFg $true
    }

    Draw-StatusFrame

    # Static UI rows (heartbeat template + settings + legend).
    $script:HeartbeatLayoutValid = $false
    Ensure-HeartbeatLayout
    Update-HeartbeatFields

    $script:UiInited = $true

    # Apply post-init console tweaks (best-effort, host-dependent).
    try { Apply-PostInitConsoleTweaks } catch { }
}

# -------------------- Console status ------------------------------------------

function Get-HealthColor([int]$ageSec, [int]$graceSec, [int]$redAtSec, [int]$phase) {
    if ($ageSec -le $graceSec) { return $script:BaseFg }
    if ($redAtSec -le ($graceSec + 1)) { $redAtSec = $graceSec + 1 }

    $r = [double]($ageSec - $graceSec) / [double]($redAtSec - $graceSec)
    if ($r -lt 0) { $r = 0 }
    if ($r -gt 1) { $r = 1 }

    $ramp = @($script:BaseFg, $UI_Color_WarningTextDim, $UI_Color_ErrorText)

    $n = $ramp.Count
    if ($n -lt 2) { return $script:BaseFg }

    $pos = $r * ($n - 1)
    $idx = [int][Math]::Floor($pos)
    if ($idx -ge ($n - 1)) { return $ramp[$n - 1] }

    $frac = $pos - $idx
    if ($frac -ge 0.5) { return $ramp[$idx + 1] }
    return $ramp[$idx]
}

function Format-Elapsed([TimeSpan]$ts) {
    if ($ts.TotalSeconds -lt 0) { $ts = [TimeSpan]::Zero }

    $d = [int]$ts.TotalDays
    $h = $ts.Hours
    $m = $ts.Minutes
    $s = $ts.Seconds

    if ($d -gt 0) { return ("{0}d {1}h {2}m {3}s" -f $d, $h.ToString("00"), $m.ToString("00"), $s.ToString("00")) }
    if ($h -gt 0) { return ("{0}h {1}m {2}s" -f $h, $m.ToString("00"), $s.ToString("00")) }
    if ($m -gt 0) { return ("{0}m {1}s" -f $m, $s.ToString("00")) }
    return ("{0}s" -f $s)
}

function Ensure-HeartbeatLayout {
    # Prepare the fixed rows below the live status lines:
    # - Heartbeat row
    # - Spacer row
    # - Settings row
    # - Separator row
    # - Legend row
    #
    # This function only ensures that those rows exist and are clean after an initial draw or a resize.
    # The heartbeat content itself is rendered by Update-HeartbeatFields.

    $w = Get-UiWidth 40

    if (-not $script:HeartbeatLayoutValid -or $w -ne $script:HeartbeatLayoutWidth) {
        $script:HeartbeatLayoutWidth = $w

        # Heartbeat row (will be overwritten by Update-HeartbeatFields).
        Write-At 0 ($script:StatusTop + 6) "" $script:BaseFg $true

        # Render separator + settings + footer in their fixed rows.
        Render-SettingsAndLegend

        # Force first field update after (re)layout.
        $script:LastHeartbeatClock = ""
        $script:LastHeartbeatElapsed = ""
        $script:LastHeartbeatElapsedFg = $script:BaseFg

        $script:HeartbeatLayoutValid = $true
    }
}

function Render-SettingsAndLegend {
    # Settings row
    $prefixCode = $script:PrefixLanguageCode
    if ([string]::IsNullOrEmpty($prefixCode)) { $prefixCode = "??" }

    $wd = ''
    try { $wd = "$($script:Settings.WorkDir)".Trim() } catch { }
    if (-not $wd) { try { $wd = (Split-Path -Parent $script:InFile) } catch { } }
    if (-not $wd) { $wd = $AppBaseDir }
    $workDirShort = Pad-OrEllipsize $wd 28

    $aState = $(if ($script:AsciiSafeEnabled) { "ON " } else { "OFF" })
    $tState = $(if ($script:TransliterationEnabled) { "ON " } else { "OFF" })

    # Keep the prefix language code in a neutral tone for consistency with the I/O labels.
    $codeFg = $script:BaseFg
    $dimFg  = $UI_Color_DimText

    # Match the F10 menu: enabled items render their values (including brackets) in InputText.
    $valueFgEnabled  = $UI_Color_InputText
    $valueFgDisabled = $UI_Color_DimText

    # ASCII-safe is always an enabled item in the F10 menu, regardless of ON/OFF.
    $aValueFg = $valueFgEnabled

    # Transliteration becomes a disabled item when ASCII-safe is ON.
    $tValueFg = if ($script:AsciiSafeEnabled) { $valueFgDisabled } else { $valueFgEnabled }

    # Determine displayed transliteration token (same text as before).
    $tDisplay = if ($script:AsciiSafeEnabled) { "ON*" } else { $tState.Trim() }

    # Show current values in square brackets for quick scanning (consistent with the F10 menu).
    $settingsSegments = @(
        @{ Text = "ASCII-safe ";             Fg = $dimFg }
        @{ Text = "[";                       Fg = $aValueFg }
        @{ Text = $aState.Trim();            Fg = $aValueFg }
        @{ Text = "]";                       Fg = $aValueFg }
        @{ Text = " | ";                     Fg = $dimFg }

        @{ Text = "Transliteration EL/CYR "; Fg = $dimFg }
        @{ Text = "[";                       Fg = $tValueFg }
        @{ Text = $tDisplay;                 Fg = $tValueFg }
        @{ Text = "]";                       Fg = $tValueFg }
        @{ Text = " | ";                     Fg = $dimFg }

        @{ Text = "Playout delimiter ";      Fg = $dimFg }
        @{ Text = "[";                       Fg = $valueFgEnabled }
        @{ Text = "$global:SepGlyph";        Fg = $valueFgEnabled }
        @{ Text = "]";                       Fg = $valueFgEnabled }
    )
# Separator line directly under the Last update row
    $w = Get-UiWidth 40
    $line = ("-" * ([Math]::Max(1, $w - 1)))
    Write-At 0 ($script:StatusTop + 7) $line DarkGray $true

    # Blank line between the separator and the control legend
    Write-At 0 ($script:StatusTop + 8) "" $script:BaseFg $true

    # Settings row (function hotkeys are shown left-to-right in F-key order)
    Write-AtSegments 0 ($script:StatusTop + 9) $settingsSegments $script:BaseFg $true

    # Exit key (Ctrl+C stops the main loop).
    $w2 = Get-UiWidth 40
    $exitHintLeft  = "F10 Settings"
    $exitHintRight = "CTRL+C Exit"
    $exitHint = "$exitHintLeft   $exitHintRight"
    $xExit = [Math]::Max(0, $w2 - $exitHint.Length - 1)

    # Hotkey hints are low-priority UI chrome. Keep the words dimmed, but show the actual key chords in bright white.
    Write-At $xExit ($script:StatusTop + 9) "F10" ($UI_Color_BrightText)
    Write-At ($xExit + 3) ($script:StatusTop + 9) " Settings" ($UI_Color_DimText)
    Write-At ($xExit + 12) ($script:StatusTop + 9) "   " ($UI_Color_DimText)
    Write-At ($xExit + 15) ($script:StatusTop + 9) "CTRL+C" ($UI_Color_BrightText)
    Write-At ($xExit + 21) ($script:StatusTop + 9) " Exit" ($UI_Color_DimText)

    # Clear unused legacy rows (kept for layout stability in smaller windows).
    Write-At 0 ($script:StatusTop + 10) "" $script:BaseFg $true
    Write-At 0 ($script:StatusTop + 11) "" $script:BaseFg $true
}

function Update-HeartbeatFields {
    $now = Get-Date
    $age = $now - $script:LastGoodUpdate
    if ($age.TotalSeconds -lt 0) { $age = [TimeSpan]::Zero }

    $ageSec = [int][Math]::Max(0, $age.TotalSeconds)
    $phase = [int]$now.Second
    $healthFg = Get-HealthColor $ageSec $HealthGraceSec $HealthRedAtSec $phase

    $clock = $now.ToString("HH:mm:ss")
    $elapsedToken = Format-Elapsed $age

    # Render the entire heartbeat row so suffixes like "ago" always stay directly attached to the elapsed token.
    # This also guarantees that the surrounding brackets are restored after any overlay menu has cleared the row.
    $segments = @(
        @{ Text = ("[{0}] Last update : " -f $clock); Fg = $script:BaseFg }
        @{ Text = $elapsedToken;                     Fg = $healthFg }
        @{ Text = " ago";                           Fg = $script:BaseFg }
    )

    Write-AtSegments 0 ($script:StatusTop + 6) $segments $script:BaseFg $true

    $script:LastHeartbeatClock = $clock
    $script:LastHeartbeatElapsed = $elapsedToken
    $script:LastHeartbeatElapsedFg = $healthFg
}

function Update-HeartbeatBar {
    if ($script:UiOverlayActive) { return }
    try { Clear-ConsoleSelectionIfActive } catch { }
    Ensure-UiFresh
    Ensure-HeartbeatLayout
    Update-HeartbeatFields

    # Update the live output block if the input availability/staleness state changed.
    $state = Get-InputUiState
    if ($state -ne $script:LastInputUiState) {
        $script:LastInputUiState = $state

        # If the input becomes unavailable, flush all output files once so downstream systems do not keep stale data.
        if ($state -eq "NotAvailable") {
            if (-not $script:OutputsFlushedForNotAvailable) {
                try { Write-OutputsAtomic "" "" "" } catch { }
                $script:OutputsFlushedForNotAvailable = $true
            }
        } else {
            $script:OutputsFlushedForNotAvailable = $false
        }

        if ($state -eq "Normal") {
            # Restore the last known values (if any) when returning to a healthy state.
            Update-Status $script:LastRawInput $script:LastPrefixOut $script:LastRtText $script:LastRtPlusText "Normal"
        } else {
            Update-Status "" "" "" "" $state
        }
    }}

function Clamp-UiLine([string]$s, [int]$maxLen) {
    if ($null -eq $s) { return "" }
    if ($maxLen -lt 1) { return "" }
    if ($s.Length -le $maxLen) { return $s }

    # Prevent console line-wrapping which can overwrite fixed UI rows.
    if ($maxLen -ge 3) { return ($s.Substring(0, $maxLen - 3) + "...") }
    return $s.Substring(0, $maxLen)
}

function Update-Status([string]$rawInput, [string]$prefixOut, [string]$rtText, [string]$rtPlusText, [string]$inputState = "Normal") {
    if ($script:UiOverlayActive) { return }
    Ensure-UiFresh

    $rawInput   = ($rawInput -replace "^\uFEFF", "")
    $rawInput   = [regex]::Replace($rawInput, "\s+", " ").Trim()

    $prefixOut  = [regex]::Replace($prefixOut, "\s+", " ").Trim()
    $rtText     = [regex]::Replace($rtText, "\s+", " ").Trim()
    $rtPlusText = [regex]::Replace($rtPlusText, "\s+", " ").Trim()

# Persist the latest computed values for redraw/refresh scenarios.
$script:LastRawInput   = $rawInput
$script:LastPrefixOut  = $prefixOut
$script:LastRtText     = $rtText
$script:LastRtPlusText = $rtPlusText

# In special UI states we show placeholders to make the absence/staleness explicit.
if ($inputState -eq "NotAvailable") {
    $rawInput   = "<not available>"
    $prefixOut  = "<none>"
    $rtText     = "<none>"
    $rtPlusText = "<none>"
} elseif ($inputState -eq "Expired") {
    $rawInput   = "<expired>"
    $prefixOut  = "<none>"
    $rtText     = "<none>"
    $rtPlusText = "<none>"
}

# Persist the latest *shown* values for UI redraw scenarios (menu overlay restore, partial refresh).
$script:LastRawInputShown   = $rawInput
$script:LastPrefixOutShown  = $prefixOut
$script:LastRtTextShown     = $rtText
$script:LastRtPlusTextShown = $rtPlusText

    if ($rawInput) { $rawInput = ([string]$rawInput).Replace([string]$SepChar, [string]$SepGlyph) }

    $ts = (Get-Date).ToString("HH:mm:ss")

    $tsPart  = ("[{0}] " -f $ts)
    $sepPart = ": "

    $labIn = "INPUT       "
    $labPx = "PREFIX OUT  "
    $labRt = "OUTPUT RT   "
    $labRp = "OUTPUT RT+  "

    $inFg = if ($inputState -ne "Normal") { $UI_Color_WarningText } elseif ([string]::IsNullOrEmpty($rawInput)) { $UI_Color_WarningText } else { $UI_Color_Input }
    # Keep PREFIX OUT in a neutral tone (same as INPUT).
    $pxFg = if ($inputState -ne "Normal") { $UI_Color_WarningText } elseif ([string]::IsNullOrEmpty($prefixOut)) { $UI_Color_WarningText } else { $UI_Color_Prefix }
    # Use accent colors for outputs (RT = green, RT+ = dark cyan) while keeping PREFIX OUT neutral.
    $rtFg = if ($inputState -ne "Normal") { $UI_Color_WarningText } elseif ([string]::IsNullOrEmpty($rtText)) { $UI_Color_WarningText } else { $UI_Color_RT }
    $rpFg = if ($inputState -ne "Normal") { $UI_Color_WarningText } elseif ([string]::IsNullOrEmpty($rtPlusText)) { $UI_Color_WarningText } else { $UI_Color_RTPlus }

    $warnActive = ($inFg -eq $UI_Color_WarningText)

    Write-SegmentedLine 0 ($script:StatusTop + 1) $tsPart $script:BaseFg $labIn $inFg $sepPart $script:BaseFg $rawInput $inFg $true
    Write-SegmentedLine 0 ($script:StatusTop + 2) $tsPart $script:BaseFg $labPx $pxFg $sepPart $script:BaseFg $prefixOut $pxFg $true
    Write-SegmentedLine 0 ($script:StatusTop + 3) $tsPart $script:BaseFg $labRt $rtFg $sepPart $script:BaseFg $rtText $rtFg $true
    Write-SegmentedLine 0 ($script:StatusTop + 4) $tsPart $script:BaseFg $labRp $rpFg $sepPart $script:BaseFg $rtPlusText $rpFg $true

    if ($warnActive -ne $script:HeaderWarnActive) {
        $script:HeaderWarnActive = $warnActive
        try { Draw-Header } catch { }
    }

    $inLine = ("{0}{1}{2}{3}" -f $tsPart, $labIn, $sepPart, $rawInput)
    $pxLine = ("{0}{1}{2}{3}" -f $tsPart, $labPx, $sepPart, $prefixOut)
    $outRt  = ("{0}{1}{2}{3}" -f $tsPart, $labRt, $sepPart, $rtText)
    $outRp  = ("{0}{1}{2}{3}" -f $tsPart, $labRp, $sepPart, $rtPlusText)

    $w = Get-UiWidth 20
    $max = $w - 1

    $inLine = Clamp-UiLine $inLine $max
    $pxLine = Clamp-UiLine $pxLine $max
    $outRt  = Clamp-UiLine $outRt  $max
    $outRp  = Clamp-UiLine $outRp  $max

    $script:LastInLine = $inLine
    $script:LastPxLine = $pxLine
    $script:LastOutRtLine = $outRt
    $script:LastOutRpLine = $outRp
    $script:LastInFg = $inFg
    $script:LastPxFg = $pxFg
    $script:LastRtFg = $rtFg
    $script:LastRpFg = $rpFg

    $script:LastInputUiState = $inputState
    $script:LastInLine = $inLine
    $script:LastPxLine = $pxLine
    $script:LastOutRtLine = $outRt
    $script:LastOutRpLine = $outRp
    $script:LastInFg = $inFg
    $script:LastPxFg = $pxFg
    $script:LastRtFg = $rtFg
    $script:LastRpFg = $rpFg
}

# -------------------- Normalization helpers ----------------------------------

function Strip-InvisibleControls([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }
    $s = [regex]::Replace($s, "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]", "")
    $s = [regex]::Replace($s, "[\u00AD\uFEFF\u200B-\u200D\u2060]", "")
    return $s
}

function Decode-BasicHtmlEntities([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }

    $s = $s.Replace("&amp;", "&").Replace("&quot;", '"').Replace("&apos;", "'")
    $s = $s.Replace("&lt;", "<").Replace("&gt;", ">").Replace("&nbsp;", " ")

    $s = [regex]::Replace($s, "&#(\d+);", {
        param($m)
        try {
            $cp = [int]$m.Groups[1].Value
            if ($cp -lt 0 -or $cp -gt 0x10FFFF) { return $m.Value }
            return [char]::ConvertFromUtf32($cp)
        } catch { return $m.Value }
    })

    $s = [regex]::Replace($s, "&#x([0-9A-Fa-f]+);", {
        param($m)
        try {
            $cp = [Convert]::ToInt32($m.Groups[1].Value, 16)
            if ($cp -lt 0 -or $cp -gt 0x10FFFF) { return $m.Value }
            return [char]::ConvertFromUtf32($cp)
        } catch { return $m.Value }
    })

    $s = $s.Replace("&#39;", "'")
    return $s
}

function Normalize-FullwidthAscii([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }

    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $cp = [int][char]$ch
        if ($cp -eq 0x3000) { [void]$sb.Append(" "); continue }
        if ($cp -ge 0xFF01 -and $cp -le 0xFF5E) { [void]$sb.Append([char]($cp - 0xFEE0)); continue }
        [void]$sb.Append($ch)
    }
    return $sb.ToString()
}

function Apply-Replacements([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }

    # Normalize a few common symbols that are not reliably supported on RDS receivers.
    $s = [regex]::Replace($s, '\u00B0\s*([cCfF])', ' $1')    # "°C" -> " C", "°F" -> " F"
    # Replace omega only in electrical-unit context (e.g. 10Ω, 4.7kΩ, 1 MΩ). Otherwise, keep it
    # as a Greek letter and let Transliterate-Greek() handle it.
    $s = [regex]::Replace(
        $s,
        '(?i)(?<=\d)\s*(?<p>k|m|g|t|u|n|p)?\s*[\u03A9\u03C9]',
        {
            param($m)
            $p = $m.Groups['p'].Value
            if ([string]::IsNullOrEmpty($p)) { return ' Ohm' }
            return " $p" + 'Ohm'
        }
    )
                $map = @{
        0x2018="'"; 0x2019="'"; 0x201B="'"; 0x2032="'"; 0x00B4="'"; 0x02BC="'"
        0x201C='"'; 0x201D='"'; 0x201E='"'; 0x00AB='"'; 0x00BB='"'
        0x2010="-"; 0x2011="-"; 0x2012="-"; 0x2013="-"; 0x2014="-"; 0x2212="-"
        0x2026="..."
        0x00A0=" "; 0x2007=" "; 0x202F=" "
        0x2022=" "; 0x00B7=" "
        0x00B0=' deg'; 0x00B5='u'; 0x00B1='+/-'; 0x00D7='x'; 0x00F7='/'
        0x00A3="GBP";   # £
        0x00A5="Yen";   # ¥
        0x00A2="cent";  # ¢
        0x0192="fl";    # ƒ (florin)
        0x20A7="Pts";   # ₧ (peseta)
        0x20AC="EUR";   # €

    }

    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $cp = [int][char]$ch
        if ($map.ContainsKey($cp)) { [void]$sb.Append($map[$cp]) } else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Cleanup-Whitespace([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return "" }
    $s = $s.Trim()
    return [regex]::Replace($s, "\s+", " ")
}

function Ensure-TrailingSpace([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # Ensure the string ends with exactly one space (useful for prefixes so they never "stick" to the artist).
    # We intentionally do not normalize internal whitespace here; callers should already have done their final-pass cleanup.
    $t = $s.TrimEnd()
    return ($t + " ")
}

function Cleanup-DanglingArtistSeparators([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # When non-Latin parts are filtered away (e.g. transliteration disabled), join tokens like "&" can be left behind.
    # This function removes separators that no longer separate two visible artist tokens, while preserving meaningful text.
    $t = Cleanup-Whitespace $s

    # If a separator is directly followed by a parenthesized token, treat it as an artist token:
    # remove the parentheses but keep the separator.
    # Example: "Ira Champion & (Blondy)" -> "Ira Champion & Blondy"
    $t = [regex]::Replace($t, "(\s*(?:&|,|/|\+)\s*)\(\s*([^\)]+?)\s*\)", '$1$2')

    # Remove leading / trailing separators.
    $t = [regex]::Replace($t, "^\s*(?:&|,|/|\+)\s*", "")
    $t = [regex]::Replace($t, "\s*(?:&|,|/|\+)\s*$", "")

    # Also remove a dangling dash separator at the start/end (e.g. "Prince -" after stripping "(EAC)").
    # Only affects standalone dash tokens (surrounded by whitespace), not hyphenated names like "AC-DC".
    $t = [regex]::Replace($t, "^\s*(?:-|–|—|−)\s+", "")
    $t = [regex]::Replace($t, "\s+(?:-|–|—|−)\s*$", "")

    return (Cleanup-Whitespace $t)
}

function Remove-ArtistAcronymSuffix([string]$artist) {
    if ([string]::IsNullOrWhiteSpace($artist)) { return "" }

    # Safely strip a trailing acronym that is merely an abbreviation of the artist name.
    # Examples:
    # - "Creedence Clearwater Revival (CCR)" -> "Creedence Clearwater Revival"
    # - "Bachman-Turner Overdrive (BTO)"     -> "Bachman-Turner Overdrive"
    # - "Creedence Clearwater Revival (C.C.R.)" -> "Creedence Clearwater Revival"
    #
    # Safety rules:
    # - Only acts on a *final* acronym token at the end of the artist field: "(...)", "[...]", "{...}" or a dash-separated suffix (" - ...").
    # - The abbreviation must be 2..6 letters (dots/spaces are allowed but ignored for the comparison).
    # - The abbreviation must match the initials (acronym) derived from the visible artist name.

    $t = Cleanup-Whitespace $artist

    # If the artist field contains multiple artists separated by "&", try stripping an acronym suffix
    # from the *last* artist only (e.g. "Olivia Newton-John & Electric Light Orchestra (ELO)").
    # This stays safe because the suffix must still match initials of that specific artist segment.
    $multi = [regex]::Match($t, '^(?<left>.+?)(?<sep>\s*&\s*)(?<right>[^&]+)$')
    if ($multi.Success) {
        $left  = Cleanup-Whitespace $multi.Groups["left"].Value
        $sep   = $multi.Groups["sep"].Value
        $right = Cleanup-Whitespace $multi.Groups["right"].Value

        $rightStripped = Remove-ArtistAcronymSuffix $right
        if ($rightStripped -ne $right) {
            return ($left + $sep + $rightStripped)
        }
    }

    # Accept common trailing abbreviation notations:
    # - "(ABBR)", "[ABBR]", "{ABBR}" at the very end of the artist field.
    # - " - ABBR" / " – ABBR" / " — ABBR" / " − ABBR" (dash-separated suffix), but only when separated by spaces.

    $m = [regex]::Match($t, '^(?<name>.+?)\s*(?:\(\s*(?<abbr>[^)]+?)\s*\)|\[\s*(?<abbr>[^\]]+?)\s*\]|\{\s*(?<abbr>[^}]+?)\s*\})\s*$')
    if (-not $m.Success) {
        $m = [regex]::Match($t, '^(?<name>.+?)\s+(?:-|–|—|−)\s+(?<abbr>.+?)\s*$')
    }
    if (-not $m.Success) { return $t }

    $name = Cleanup-Whitespace $m.Groups["name"].Value
    $abbr = Cleanup-Whitespace $m.Groups["abbr"].Value

    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($abbr)) { return $t }

    # Normalize the abbreviation: keep only letters, and remove dot-separated styles (e.g. "C.C.R.").
    $abbrKey = [regex]::Replace($abbr.ToUpperInvariant(), '[^A-Z]', '')
    if ($abbrKey.Length -lt 2 -or $abbrKey.Length -gt 6) { return $t }

    # Build an acronym from the artist name:
    # - Split on spaces and hyphens.
    # - Take the first letter of each token that starts with a letter.
    $nameNorm = [regex]::Replace($name, "[\u2010-\u2015\u2212]", "-")
    $tokens = [regex]::Split($nameNorm, '[\s\-]+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    # Common stopwords that are typically not included in band acronyms (e.g. "Orchestral Manoeuvres In The Dark" -> OMD).
    # Keep this list intentionally conservative; the abbreviation must still match exactly, so this is safe by design.
    $stopWords = @(
        "A","AN","AND","THE","IN","OF","TO","FOR","ON","AT","BY","FROM","WITH",
        "DE","DA","DI","LA","LE","EL","LOS","LAS","DER","DIE","DAS","DEN","UND","ET","EN"
    )

    $initialsAll    = New-Object System.Text.StringBuilder
    $initialsNoStop = New-Object System.Text.StringBuilder

    foreach ($tok in $tokens) {
        $c = $tok.Trim()
        if ($c.Length -lt 1) { continue }

        $first = $c.Substring(0,1)
        if ($first -notmatch '^[A-Za-z]$') { continue }

        $uFirst = $first.ToUpperInvariant()
        [void]$initialsAll.Append($uFirst)

        $uTok = $c.ToUpperInvariant()
        if ($stopWords -contains $uTok) { continue }
        [void]$initialsNoStop.Append($uFirst)
    }

    $nameKeyAll    = $initialsAll.ToString()
    $nameKeyNoStop = $initialsNoStop.ToString()

    if ($nameKeyAll.Length -lt 2 -or $nameKeyAll.Length -gt 10) { return $t }

    if ($abbrKey -eq $nameKeyAll -or ($nameKeyNoStop.Length -ge 2 -and $abbrKey -eq $nameKeyNoStop)) {
        return $name
    }

    return $t
}

function AsciiSafe-FinalPass([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # Final output pass for "ASCII-safe" mode:
    # - Remove control characters and invisible format characters.
    # - Strip diacritics (e.g., "é" -> "e") and map a small set of Latin letters that do not decompose cleanly.
    # - Keep *only* printable ISO-646 ASCII (0x20..0x7E), as this mode is meant to be fully diacritic-free.

    $t = $s

    # Strip ASCII control characters.
    $t = [regex]::Replace($t, "[\x00-\x1F\x7F]", "")

    # Strip common invisible / zero-width format chars (explicit ranges; avoids embedding invisible literals in source).
    $t = [regex]::Replace($t, "[\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]", "")

    # Remove standalone empty bracket tokens (e.g., "[]", "( )", "{ }", "< >") without touching bracketed content.
    # This only removes tokens that are isolated by whitespace (or string edges), so "Song (Live)" remains intact.
    $t = [regex]::Replace($t, '(?<!\S)[\[\(\{\<]\s*[\]\)\}\>](?!\S)', '')

    # Normalize to decomposed form so diacritics become combining marks, then remove those marks.
    try { $t = $t.Normalize([Text.NormalizationForm]::FormD) } catch { }
    $t = [regex]::Replace($t, "\p{M}+", "")

    # Map a few Latin letters that are commonly encountered but do not decompose into ASCII base letters.
    # (This keeps the behavior predictable in ASCII-safe mode.)
    $t = $t.Replace("ß", "ss").Replace("ẞ", "SS")
    $t = $t.Replace("Æ", "AE").Replace("æ", "ae")
    $t = $t.Replace("Œ", "OE").Replace("œ", "oe")
    $t = $t.Replace("Ø", "O").Replace("ø", "o")
    $t = $t.Replace("Ð", "D").Replace("ð", "d")
    $t = $t.Replace("Þ", "TH").Replace("þ", "th")
    $t = $t.Replace("Ł", "L").Replace("ł", "l")

    $t = $t.Replace("Đ", "D").Replace("đ", "d")
    $t = $t.Replace("Ĳ", "IJ").Replace("ĳ", "ij")
$t = $t.Replace("Ǆ", "DZ").Replace("ǅ", "Dz").Replace("ǆ", "dz")
$t = $t.Replace("Ǉ", "LJ").Replace("ǈ", "Lj").Replace("ǉ", "lj")
$t = $t.Replace("Ǌ", "NJ").Replace("ǋ", "Nj").Replace("ǌ", "nj")
    $t = $t.Replace("ı", "i")

    # Normalize common Unicode punctuation to ASCII equivalents (helps avoid losing dashes/quotes in ASCII-safe mode).
    $t = $t.Replace("–", "-").Replace("—", "-").Replace("−", "-")
    $t = $t.Replace('’','''').Replace('‘','''').Replace('“','"').Replace('”','"')

    # Keep only printable ASCII.
    $t = [regex]::Replace($t, "[^\x20-\x7E]", "")

    return (Cleanup-Whitespace $t)
}

function PrefixSafe-FinalPass([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # Prefix output pass:
    # - Keep Unicode letters/symbols (for chains that truly support them).
    # - Still strip control and invisible format characters.
    # - Normalize internal whitespace but *preserve* a trailing space so the prefix never "sticks" to the artist.
    $t = $s

    # Strip ASCII control characters.
    $t = [regex]::Replace($t, "[\x00-\x1F\x7F]", "")

    # Strip common invisible / zero-width format chars.
    $t = [regex]::Replace($t, "[\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]", "")

    # Normalize whitespace to single spaces (do not TrimEnd).
    $t = [regex]::Replace($t, "\s+", " ").TrimStart()

    if (-not $t.EndsWith(" ")) { $t += " " }
    return $t
}

function UnicodeSafe-FinalPass([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # Unicode-safe output pass (used when transliteration is OFF):
    # - Keep Unicode letters/symbols (including Greek/Cyrillic), because the user explicitly disabled transliteration.
    # - Still strip ASCII control chars and invisible/format characters that may upset parsers or receivers.
    # - Normalize whitespace.
    $t = $s

    # Strip ASCII control characters.
    $t = [regex]::Replace($t, "[\x00-\x1F\x7F]", "")

    # Strip common invisible / zero-width format chars.
    $t = [regex]::Replace($t, "[\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]", "")

    # Remove standalone empty bracket tokens.
    $t = [regex]::Replace($t, '(?<!\S)[\[\(\{\<]\s*[\]\)\}\>](?!\S)', '')

    return (Cleanup-Whitespace $t)
}

function Transliterate-Cyrillic([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }

    # Cyrillic to Latin transliteration (broad coverage: Russian + common East/South Slavic letters).
    # This is intentionally ASCII-only to keep downstream RDS filtering predictable.

    $map = @{
        # Russian base
        0x0410="A";0x0411="B";0x0412="V";0x0413="G";0x0414="D";0x0415="E";0x0401="Yo";0x0416="Zh";0x0417="Z";0x0418="I";0x0419="Y";0x041A="K";0x041B="L";0x041C="M";0x041D="N";0x041E="O";0x041F="P";0x0420="R";0x0421="S";0x0422="T";0x0423="U";0x0424="F";0x0425="Kh";0x0426="Ts";0x0427="Ch";0x0428="Sh";0x0429="Shch";0x042A="";0x042B="Y";0x042C="";0x042D="E";0x042E="Yu";0x042F="Ya";
        0x0430="a";0x0431="b";0x0432="v";0x0433="g";0x0434="d";0x0435="e";0x0451="yo";0x0436="zh";0x0437="z";0x0438="i";0x0439="y";0x043A="k";0x043B="l";0x043C="m";0x043D="n";0x043E="o";0x043F="p";0x0440="r";0x0441="s";0x0442="t";0x0443="u";0x0444="f";0x0445="kh";0x0446="ts";0x0447="ch";0x0448="sh";0x0449="shch";0x044A="";0x044B="y";0x044C="";0x044D="e";0x044E="yu";0x044F="ya";

        # Ukrainian / Belarusian / common extended letters
        0x0404="Ye";0x0454="ye"; # Є
        0x0406="I";0x0456="i";   # І
        0x0407="Yi";0x0457="yi"; # Ї
        0x0490="G";0x0491="g";   # Ґ
        0x040E="U";0x045E="u";   # Ў (Belarusian)

        # Serbian/Macedonian (and related)
        0x0402="Dj";0x0452="dj"; # Ђ
        0x0403="Gj";0x0453="gj"; # Ѓ
        0x0405="Dz";0x0455="dz"; # Ѕ
        0x0408="J"; 0x0458="j";  # Ј
        0x0409="Lj";0x0459="lj"; # Љ
        0x040A="Nj";0x045A="nj"; # Њ
        0x040B="C"; 0x045B="c";  # Ћ
        0x040C="Kj";0x045C="kj"; # Ќ
        0x040F="Dzh";0x045F="dzh" # Џ
    }

    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $cp = [int][char]$ch
        if ($map.ContainsKey($cp)) { [void]$sb.Append($map[$cp]) } else { [void]$sb.Append($ch) }
    }

    return $sb.ToString()
}

function Transliterate-Greek([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }

    # Greek to Latin transliteration.
    # Important: handle precomposed accented vowels (tonos/dialytika) and common digraphs first.
    # This avoids dropping vowels when later filtering removes non-Latin characters.

    $t = $s
    # Common digraphs (minimal, predictable set; processed before single-letter mapping).
    # Note: PowerShell hashtables are case-insensitive by default, so we must use an Ordinal comparer
    # to keep Greek casing variants as distinct keys.
    $digraphs = [hashtable]::new([System.StringComparer]::Ordinal)

    $digraphs['αι'] = 'ai'; $digraphs['Αι'] = 'Ai'; $digraphs['ΑΙ'] = 'AI'
    $digraphs['ει'] = 'ei'; $digraphs['Ει'] = 'Ei'; $digraphs['ΕΙ'] = 'EI'
    $digraphs['οι'] = 'oi'; $digraphs['Οι'] = 'Oi'; $digraphs['ΟΙ'] = 'OI'
    $digraphs['ου'] = 'ou'; $digraphs['Ου'] = 'Ou'; $digraphs['ΟΥ'] = 'OU'
    $digraphs['ευ'] = 'eu'; $digraphs['Ευ'] = 'Eu'; $digraphs['ΕΥ'] = 'EU'
    $digraphs['αυ'] = 'au'; $digraphs['Αυ'] = 'Au'; $digraphs['ΑΥ'] = 'AU'

    $digraphs['Στ'] = 'St'; $digraphs['στ'] = 'st'; $digraphs['ΣΤ'] = 'ST'
    $digraphs['Τσ'] = 'Ts'; $digraphs['τσ'] = 'ts'; $digraphs['ΤΣ'] = 'TS'
    $digraphs['Τζ'] = 'Tz'; $digraphs['τζ'] = 'tz'; $digraphs['ΤΖ'] = 'TZ'
    $digraphs['Γκ'] = 'Gk'; $digraphs['γκ'] = 'gk'; $digraphs['ΓΚ'] = 'GK'
    $digraphs['Ντ'] = 'Nt'; $digraphs['ντ'] = 'nt'; $digraphs['ΝΤ'] = 'NT'
    $digraphs['Μπ'] = 'Mp'; $digraphs['μπ'] = 'mp'; $digraphs['ΜΠ'] = 'MP'
    foreach ($k in $digraphs.Keys) {
        $t = $t.Replace($k, $digraphs[$k])
    }

    $map = @{
        # Uppercase
        0x0391="A";0x0392="V";0x0393="G";0x0394="D";0x0395="E";0x0396="Z";0x0397="I";0x0398="Th";0x0399="I";0x039A="K";0x039B="L";0x039C="M";0x039D="N";0x039E="X";0x039F="O";0x03A0="P";0x03A1="R";0x03A3="S";0x03A4="T";0x03A5="Y";0x03A6="F";0x03A7="Ch";0x03A8="Ps";0x03A9="O";

        # Lowercase
        0x03B1="a";0x03B2="v";0x03B3="g";0x03B4="d";0x03B5="e";0x03B6="z";0x03B7="i";0x03B8="th";0x03B9="i";0x03BA="k";0x03BB="l";0x03BC="m";0x03BD="n";0x03BE="x";0x03BF="o";0x03C0="p";0x03C1="r";0x03C3="s";0x03C2="s";0x03C4="t";0x03C5="y";0x03C6="f";0x03C7="ch";0x03C8="ps";0x03C9="o";

        # Precomposed tonos vowels (Greek and Coptic)
        0x0386="A";0x03AC="a"; # Ά ά
        0x0388="E";0x03AD="e"; # Έ έ
        0x0389="I";0x03AE="i"; # Ή ή
        0x038A="I";0x03AF="i"; # Ί ί
        0x038C="O";0x03CC="o"; # Ό ό
        0x038E="Y";0x03CD="y"; # Ύ ύ
        0x038F="O";0x03CE="o"; # Ώ ώ

        # Dialytika variants
        0x03AA="I";0x03CA="i"; # Ϊ ϊ
        0x03AB="Y";0x03CB="y"; # Ϋ ϋ
        0x0390="i";             # ΐ (iota with dialytika and tonos)
        0x03B0="y"              # ΰ (upsilon with dialytika and tonos)
    }

    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $t.ToCharArray()) {
        $cp = [int][char]$ch
        if ($map.ContainsKey($cp)) { [void]$sb.Append($map[$cp]) } else { [void]$sb.Append($ch) }
    }

    return $sb.ToString()
}

function Filter-ToRdsLatin([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return "" }

    # When transliteration is disabled, do NOT drop non-Latin scripts.
    # The toggle is meant to choose between (a) transliterating to Latin or (b) keeping the original script.
    if (-not $script:TransliterationEnabled) {
        return (UnicodeSafe-FinalPass $s)
    }

    # Transliteration is enabled: drop combining marks and keep a conservative "Latin-ish" repertoire.
    $t = [regex]::Replace($s, "\p{M}+", "")
    $t = [regex]::Replace($t, "[^\x20-\x7E\u00A1-\u00FF\u0100-\u017F\u0180-\u024F]", "")
    return (Cleanup-Whitespace $t)
}

# -------------------- Always-remove tag helpers -------------------------------

function Strip-EacTag([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }

    # Remove "(EAC)" or "[EAC]" anywhere (case-insensitive), including surrounding whitespace.
    $t = [regex]::Replace($s, "\s*[\(\[]\s*EAC\s*[\)\]]\s*", " ", "IgnoreCase")
    return (Cleanup-Whitespace $t)
}

function Is-AlwaysRemoveTagToken([string]$token) {
    if ([string]::IsNullOrWhiteSpace($token)) { return $false }

    $t = (Cleanup-Whitespace $token).Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return $false }

    # Primary always-remove allowlist (strict).
    if ($t -match '^(?i)(?:EAC|Exact\s+Audio\s+Copy|ReplayGain|MP3Gain|AACGain|Sound\s*Check|SoundCheck|Normalized|Normalised|Normalization|Normalisation)$') { return $true }

    # Common encoders / rippers / taggers (remove only when isolated inside brackets).
    if ($t -match '^(?i)(?:LAME(?:\s*MP3\s*Encoder)?(?:\s*\d+(?:\.\d+)*)?|Fraunhofer|iTunes|XLD|CDex|dBpoweramp|MediaMonkey|MusicBrainz(?:\s+Picard)?|Picard|Spotify|Apple\s+Music|Amazon\s+Music|YouTube\s+Music|SoundCloud|Deezer|TIDAL|Bandcamp)$') { return $true }

    # DJ / library tools (remove only when isolated inside brackets).
    if ($t -match '^(?i)(?:Serato(?:\s+Edit)?|Traktor|Rekordbox|VirtualDJ|Mixxx|Pioneer\s*DJ)$') { return $true }

    # Scene / release-ish markers (remove only when isolated inside brackets).
    if ($t -match '^(?i)(?:WEB(?:-DL)?|WEBRIP|CDRIP|CD\s*RIP|PROMO|ADVANCE|RETAIL|SCENE|VINYL\s*RIP|CASSETTE\s*RIP)$') { return $true }

    # Technical/container/bitrate tokens (remove only when the token is clearly "format noise").
    # Examples: "MP3 320", "320kbps", "V0", "CBR", "FLAC", "24bit 96kHz", "Hi-Res"
    if ($t -match '^(?i)(?:MP3|MP4|FLAC|WAV|AAC|OGG|OPUS|M4A|WMA|ALAC|AIFF)(?:[\s\-\._]*(?:\d{2,3}\s*kbps|\d{2,3}k|V0|V1|V2|CBR|VBR|ABR|LOSSLESS|HI-?RES|24\s*BIT|16\s*BIT|\d{2,3}(?:\.\d+)?\s*K?HZ))*$') { return $true }
    if ($t -match '^(?i)(?:\d{2,3}\s*kbps|\d{2,3}k|V0|V1|V2|CBR|VBR|ABR|LOSSLESS|HI-?RES|24\s*BIT|16\s*BIT|\d{2,3}(?:\.\d+)?\s*K?HZ)$') { return $true }

    return $false
}

function Strip-AlwaysRemoveNoiseTags([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }

    # Keep the explicit EAC behavior intact (historical behavior).
    $t = Strip-EacTag $s

    # Remove always-remove tokens if they occur as isolated bracketed groups: "(...)" "[...]" "{...}".
    # This is intentionally conservative to avoid false positives in real titles.
    $pattern = '\s*[\(\[\{]\s*(?<tok>[^\)\]\}]{1,48})\s*[\)\]\}]\s*'

    $changed = $true
    while ($changed) {
        $changed = $false
        $t2 = [regex]::Replace($t, $pattern, {
            param($m)

            $tok = $m.Groups['tok'].Value
            if (Is-AlwaysRemoveTagToken $tok) {
                $script:__stripChanged = $true
                return ' '
            }
            return $m.Value
        }, "CultureInvariant")

        if ($script:__stripChanged) {
            $script:__stripChanged = $false
            $t = $t2
            $changed = $true
        }
    }

    return (Cleanup-Whitespace $t)
}

# -------------------- Track number / filename parsing helpers -----------------

function Strip-TrackNumberPrefix([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Remove common track number prefixes: "03. ", "03 - ", "(03) ", "[03] ", "03: ", etc.
    $t2 = [regex]::Replace(
        $t,
        "^\s*(?:\(\s*)?(?:\[\s*)?\d{1,3}(?:\s*\])?(?:\s*\))?\s*[\.\-_:)\]]\s+",
        "",
        "CultureInvariant"
    )

    if ($t2 -and $t2 -ne $t) { return $t2.Trim() }
    return $t
}

function Strip-TrackNumberPrefixLoose([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Conservative:
    # Only strip a 2-digit prefix when it is clearly separated from the artist/title by an unambiguous delimiter.
    #
    # Accepted examples:
    #   "03. Artist"     "03 - Artist"     "03: Artist"
    #   "(03) Artist"    "[03] Artist"     "{03} Artist"
    #
    # Rejected examples (to avoid damaging legitimate artist names):
    #   "50 Cent"        "77 Bombay Street"
    $m = [regex]::Match(
        $t,
        "^\s*(?:(?:\(\s*|\[\s*|\{\s*)?(?<n>\d{2})(?:\s*(?<closer>\)|\]|\}))\s+(?<next>.)|(?<n>\d{2})\s*(?<sep>[\.\-_:])\s+(?<next>.))",
        "CultureInvariant"
    )

    if (-not $m.Success) { return $t }

    $next = $m.Groups["next"].Value
    if (-not $next) { return $t }

    # Keep the first character by cutting from the 'next' group index.
    return $t.Substring($m.Groups["next"].Index).Trim()
}


# -------------------- Country-prefix stripping (title) -------------------------

# Some sources prepend a country/region label to the *title* field, e.g. "The Netherlands- Walk Along".
# This helper strips such a prefix conservatively:
# - Only acts when a recognized country name appears at the very start of the title.
# - Requires an immediate separator ("-", "–", "—", ":") followed by whitespace and real remaining content.
# - Country list is built from .NET cultures at runtime (English country names) and cached.
$script:_CountryPrefixRegex = $null
$script:_CountryAliases = $null

function Get-CountryAliases() {
    if ($script:_CountryAliases) { return $script:_CountryAliases }

    # Legacy / alternate English country names and common metadata aliases.
    # This list is shared across:
    # - Title country-prefix stripping (e.g., "Belgium - Walk Along")
    # - Artist country/region suffix stripping (e.g., "Artist (Belgium)")
    $script:_CountryAliases = @(
        "UK",
        "U.K.",
        "Great Britain",
        "Britain",
        "USA",
        "U.S.A.",
        "US",
        "U.S.",
        "UAE",
        "U.A.E.",
        "Holland",
        "Czech Republic",
        "The Czech Republic",
        "Czechia",
        "F.Y.R. Macedonia",
        "FYR Macedonia",
        "North Macedonia",
        "Republic of North Macedonia",
        "Serbia & Montenegro",
        "Yugoslavia",
        "Russian Federation",
        "Byelorussia",
        "Türkiye",
        "Albanie",
        "Armenie"
    )

    return $script:_CountryAliases
}

function Get-CountryPrefixRegex() {
    if ($script:_CountryPrefixRegex) { return $script:_CountryPrefixRegex }

    $names = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($c in [System.Globalization.CultureInfo]::GetCultures([System.Globalization.CultureTypes]::SpecificCultures)) {
            try {
                $ri = New-Object System.Globalization.RegionInfo($c.Name)
                if ($ri -and -not [string]::IsNullOrWhiteSpace($ri.EnglishName)) {
                    [void]$names.Add($ri.EnglishName.Trim())
                }
                if ($ri -and -not [string]::IsNullOrWhiteSpace($ri.TwoLetterISORegionName)) {
                    [void]$names.Add($ri.TwoLetterISORegionName.Trim())
                }
            } catch { }
        }
    } catch { }

    # Add a few common legacy/alternate English country names that RegionInfo may not emit on this system.
    foreach ($alias in (Get-CountryAliases)) {
        if (-not [string]::IsNullOrWhiteSpace($alias)) { [void]$names.Add($alias.Trim()) }
    }

    foreach ($n in @("Netherlands","United States","United Kingdom","Czech Republic","Philippines","United Arab Emirates")) {
        if ($names.Contains($n)) { [void]$names.Add("The $n") }
    }

    $arr = @($names)
    # Prefer longer matches first (avoids partial matches when one name is a prefix of another).
    $arr = $arr | Sort-Object { $_.Length } -Descending

    $alts = @()
    foreach ($n in $arr) { $alts += [regex]::Escape($n) }

    if ($alts.Count -eq 0) {
        # Fallback: nothing to match.
        $script:_CountryPrefixRegex = [regex]'(?!)'
        return $script:_CountryPrefixRegex
    }

    $pattern = "^(?<cc>(?:$($alts -join '|')))\s*[-–—:]\s*(?<rest>.+)$"
    $script:_CountryPrefixRegex = New-Object System.Text.RegularExpressions.Regex($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return $script:_CountryPrefixRegex
}

function Strip-CountryPrefix([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Support bracketed country prefixes in titles, e.g. "(Belgium) Song" or "[F.Y.R. Macedonia] Track".
    # We only strip when the bracketed token is recognized as a country name/alias.
    if ($t -match '^\s*[\(\[\{]\s*(?<cc>[^\)\]\}]+?)\s*[\)\]\}]\s*(?<rest>.+)$') {
        $cc   = (Cleanup-Whitespace $matches['cc']).Trim()
        $rest = Cleanup-Whitespace $matches['rest']
        if (-not [string]::IsNullOrWhiteSpace($cc) -and (Test-IsCountryToken $cc)) {
            if (-not [string]::IsNullOrWhiteSpace($rest) -and ($rest -match '[\p{L}\p{N}]')) {
                return $rest
            }
        }
    }

    # Prefix form: "<country> - <title>" / "<country>: <title>"
    $rx = Get-CountryPrefixRegex
    $m  = $rx.Match($t)
    if (-not $m.Success) { return $t }

    $rest = Cleanup-Whitespace $m.Groups["rest"].Value
    if ([string]::IsNullOrWhiteSpace($rest)) { return $t }

    # Extra safety: only strip when something "title-like" remains (at least one letter or digit).
    if ($rest -notmatch '[\p{L}\p{N}]') { return $t }

    return $rest
}

function Strip-CountrySuffix([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = Cleanup-Whitespace $s

    # Strip a trailing country/region tag that is clearly metadata and not part of the string.
    # Supported (end of field only):
    # - Bracketed suffixes:  "Title (Netherlands)", "Track [Belgium]", "Name {Japan}"
    # - Hyphen suffixes:     "Title - Netherlands", "Track – Belgium", "Name — Japan"
    # - Country/region codes (ISO2): "Title (US)", "Track [UK]", "Name {DE}"
    #
    # This is intentionally conservative: we only strip a *final* token at the end.

    Ensure-CountryData

    # --- 1) Two-letter country/region codes (ISO2) ---
    $m = [regex]::Match($t, '^(?<name>.+?)\s*(?:\(\s*(?<cc>[A-Z]{2})\s*\)|\[\s*(?<cc>[A-Z]{2})\s*\]|\{\s*(?<cc>[A-Z]{2})\s*\})\s*$')
    if ($m.Success) {
        $name = Cleanup-Whitespace $m.Groups["name"].Value
        $cc   = ($m.Groups["cc"].Value).ToUpperInvariant()

        if (-not [string]::IsNullOrWhiteSpace($name) -and -not [string]::IsNullOrWhiteSpace($cc)) {
            if ($script:_CountryIso2Set.Contains($cc)) { return $name }
        }
        return $t
    }

    # --- 2) Bracketed suffixes: (Country) / [Country] / {Country} ---
    $m2 = [regex]::Match($t, '^(?<name>.+?)\s*(?:\(\s*(?<tag>[^)\]]+?)\s*\)|\[\s*(?<tag>[^\]]+?)\s*\]|\{\s*(?<tag>[^}]+?)\s*\})\s*$')
    if ($m2.Success) {
        $name2 = Cleanup-Whitespace $m2.Groups["name"].Value
        $tag2  = Cleanup-Whitespace $m2.Groups["tag"].Value

        if (-not [string]::IsNullOrWhiteSpace($name2) -and (Test-IsCountryToken $tag2)) {
            return $name2
        }
    }

    # --- 3) Hyphen/ndash/mdash suffixes: " - Country" / " – Country" / " — Country" ---
    $m3 = [regex]::Match($t, '^(?<name>.+?)\s*[-–—]\s*(?<tag>[^-–—]+?)\s*$')
    if ($m3.Success) {
        $name3 = Cleanup-Whitespace $m3.Groups["name"].Value
        $tag3  = Cleanup-Whitespace $m3.Groups["tag"].Value

        if (-not [string]::IsNullOrWhiteSpace($name3) -and (Test-IsCountryToken $tag3)) {
            return $name3
        }
    }

    return $t
}



function Is-TrackNumberOnly([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    $t = $s.Trim()
    return [regex]::IsMatch($t, "^(?:\(\s*)?\d{1,3}(?:\s*\))?$|^(?:\[\s*)?\d{1,3}(?:\s*\])?$")
}

function Try-ParseArtistTitleFromFilename([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }

    $t = Cleanup-Whitespace $s
    $t = [regex]::Replace($t, "[\u2010-\u2015\u2212]", "-")

    $t = Strip-TrackNumberPrefix $t
    $t = Cleanup-Whitespace $t
    if ([string]::IsNullOrWhiteSpace($t)) { return $null }

    # Pattern: "[Artist] Title" (and "(Artist) Title" / "{Artist} Title")
    # Allow an optional dash directly after the closing bracket so inputs like:
    #   "[Wow] - Keer Op Keer"
    # do not produce "Wow - - Keer Op Keer" after formatting.
    $m = [regex]::Match($t, "^\s*(?:\[(?<a>[^\[\]]+)\]|\((?<a>[^\(\)]+)\)|\{(?<a>[^\{\}]+)\})\s*(?:[-–—−]\s*)?(?<b>.+?)\s*$")
    if ($m.Success) {
        $a = Cleanup-Whitespace $m.Groups["a"].Value
        $b = Cleanup-Whitespace $m.Groups["b"].Value

        # Defensive: collapse any leading dash-run that may still be present.
        $b = [regex]::Replace($b, "^\s*(?:[-–—−]\s*)+", "")
        $b = Cleanup-Whitespace $b

        if ($a -and $b) { return [pscustomobject]@{ Artist = $a; Title = $b } }
    }

    # Pattern: "Artist - Title"
    $m = [regex]::Match($t, "^\s*(?<a>.+?)\s*-\s*(?<b>.+?)\s*$")
    if ($m.Success) {
        $a = Cleanup-Whitespace $m.Groups["a"].Value
        $b = Cleanup-Whitespace $m.Groups["b"].Value

        # If the title itself starts with a dash (e.g. "Artist - - Title"), collapse the run.
        $b = [regex]::Replace($b, "^\s*(?:[-–—−]\s*)+", "")
        $b = Cleanup-Whitespace $b

        if ($a -and $b) { return [pscustomobject]@{ Artist = $a; Title = $b } }
    }

    return $null
}

# -------------------- Identity / dedup helpers --------------------------------

function Normalize-IdentityKey([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    $t = $s.ToLowerInvariant()

    # Normalize to decomposed form so both "é" and "e◌́" compare identically.
    try { $t = $t.Normalize([Text.NormalizationForm]::FormD) } catch { }

    # Remove combining marks.
    $t = [regex]::Replace($t, "\p{M}+", "")

    # Normalize whitespace.
    $t = [regex]::Replace($t, "\s+", " ").Trim()

    # Replace non letters/digits with spaces.
    $t = [regex]::Replace($t, "[^\p{L}\p{Nd}]+", " ")
    $t = [regex]::Replace($t, "\s+", " ").Trim()

    return $t
}

function Normalize-NameKey([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    $t = $s

    # Drop bracketed qualifiers (conservative).
    $t = [regex]::Replace($t, "\s*[\(\[].*?[\)\]]\s*", " ").Trim()
    $t = [regex]::Replace($t, "\s+", " ").Trim()

    # Drop common descriptive tails that should not affect identity matching.
    $t = [regex]::Replace($t, "\s+\b(of|from)\b\s+.+$", "", "IgnoreCase").Trim()

    return (Normalize-IdentityKey $t)
}

function Get-ArtistNameKeys([string]$artist) {
    if ([string]::IsNullOrWhiteSpace($artist)) { return $null }

    $a = Cleanup-Whitespace $artist

    # Use Regex.Split with explicit options (avoid PowerShell -split option quirks).
    $rx = New-Object System.Text.RegularExpressions.Regex(
        "\s*(?:,|&|/|;|\+|\band\b|\bfeat\.?(?=\s|$)|\bft\.?(?=\s|$)|\bfeaturing\b)\s*",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $parts = $rx.Split($a)

    $set = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($p in $parts) {
        $name = Cleanup-Whitespace $p
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $key = Normalize-NameKey $name
        if (-not [string]::IsNullOrWhiteSpace($key)) { [void]$set.Add($key) }
    }

    return $set
}

function GuestIsAlreadyCreditedInArtist([string]$artist, [string]$guest) {
    if ([string]::IsNullOrWhiteSpace($artist) -or [string]::IsNullOrWhiteSpace($guest)) { return $false }

    $set = Get-ArtistNameKeys $artist
    if ($null -eq $set -or $set.Count -lt 1) { return $false }

    $g = Cleanup-Whitespace $guest
    $g = [regex]::Replace($g, "\s+\b(of|from)\b\s+.+$", "", "IgnoreCase").Trim()
    if ([string]::IsNullOrWhiteSpace($g)) { return $false }

    $gKey = Normalize-NameKey $g
    if ([string]::IsNullOrWhiteSpace($gKey)) { return $false }

    return $set.Contains($gKey)
}

function Strip-FeatInTitleIfGuestsAlreadyInArtist([string]$artist, [string]$title) {
    if ([string]::IsNullOrWhiteSpace($artist) -or [string]::IsNullOrWhiteSpace($title)) { return $title }

    # Case A: "(feat. X)" or "[feat. X]" at the very end.
    $patternBracket = "\s*[\(\[]\s*(?:feat\.?|ft\.?|featuring)\b\s*(?<g>[^)\]]+?)\s*[\)\]]\s*$"

    # Case B: " feat. X" at the very end (no brackets).
    $patternBare    = "\s+(?:feat\.?|ft\.?|featuring)\b\s*(?<g>.+?)\s*$"

    $m = [regex]::Match($title, $patternBracket, "IgnoreCase")
    if (-not $m.Success) { $m = [regex]::Match($title, $patternBare, "IgnoreCase") }
    if (-not $m.Success) { return $title }

    $guestRaw = Cleanup-Whitespace $m.Groups["g"].Value
    if ([string]::IsNullOrWhiteSpace($guestRaw)) { return $title }

    $gTokens = [regex]::Split(
        $guestRaw,
        "\s*(?:,|&|/|;|\+|\band\b)\s*",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    foreach ($g in $gTokens) {
        $gg = Cleanup-Whitespace $g
        if (-not $gg) { return $title }

        $gg = [regex]::Replace($gg, "\s+\b(of|from)\b\s+.+$", "", "IgnoreCase").Trim()
        if (-not $gg) { return $title }

        if (-not (GuestIsAlreadyCreditedInArtist $artist $gg)) { return $title }
    }

    $head = $title.Substring(0, $m.Index).TrimEnd()
    return (Cleanup-Whitespace $head)
}

function Strip-WithInTitleIfGuestsAlreadyInArtist([string]$artist, [string]$title) {
    if ([string]::IsNullOrWhiteSpace($artist) -or [string]::IsNullOrWhiteSpace($title)) { return $title }

    # Match a trailing guest tail in the TITLE where the guest is already credited in the ARTIST field.
    # Supported forms (end-of-title only):
    # - "(with X)" / "[with X]"  (and localized variants)
    # - " - with X" (and localized variants)
    # Keywords: with, met, mit, con, avec, com, w/, &

    $pattern = "\s*(?:-\s*|[\(\[]\s*)(?:with|met|mit|con|avec|com|w\/|&)\s+(?<g>[^\)\]]+?)\s*(?:[\)\]]\s*)?$"

    $m = [regex]::Match($title, $pattern, "IgnoreCase")
    if (-not $m.Success) { return $title }

    $guestRaw = Cleanup-Whitespace $m.Groups["g"].Value
    if ([string]::IsNullOrWhiteSpace($guestRaw)) { return $title }

    $gTokens = [regex]::Split(
        $guestRaw,
        "\s*(?:,|&|/|;|\+|\band\b)\s*",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    foreach ($g in $gTokens) {
        $gg = Cleanup-Whitespace $g
        if (-not $gg) { return $title }

        $gg = [regex]::Replace($gg, "\s+\b(of|from)\b\s+.+$", "", "IgnoreCase").Trim()
        if (-not $gg) { return $title }

        if (-not (GuestIsAlreadyCreditedInArtist $artist $gg)) { return $title }
    }

    $head = $title.Substring(0, $m.Index).TrimEnd()
    return (Cleanup-Whitespace $head)
}

function Strip-ArtistDuplicateTitleTail([string]$artist, [string]$title) {
    if ([string]::IsNullOrWhiteSpace($artist) -or [string]::IsNullOrWhiteSpace($title)) { return $title }

    # Strip a trailing " - <artist>" (or " – <artist>" / " — <artist>") only if the tail matches a name
    # already credited in the ARTIST field. This prevents obvious duplicates like:
    # - "Song Title - The Melody Sisters"
    #
    # Intentionally conservative: only strips when the suffix matches an already-credited artist; allows optional whitespace around the dash.

    $pattern = "^(?<h>.+)\s*[-–—]\s*(?<t>.+?)\s*$"
    $m = [regex]::Match($title, $pattern, "IgnoreCase")
    if (-not $m.Success) { return $title }

    $tail = Cleanup-Whitespace $m.Groups["t"].Value
    if ([string]::IsNullOrWhiteSpace($tail)) { return $title }

    if (-not (GuestIsAlreadyCreditedInArtist $artist $tail)) { return $title }

    $head = Cleanup-Whitespace $m.Groups["h"].Value
    return $head
}


function Strip-ArtistDuplicateTitlePrefix([string]$artist, [string]$title) {
    if ([string]::IsNullOrWhiteSpace($artist) -or [string]::IsNullOrWhiteSpace($title)) { return $title }

    # Strip a leading "<artist> - " (or with en-dash/em-dash variants) only if the prefix matches a name already credited
    # in the ARTIST field. This prevents obvious duplicates like:
    # - "The Melody Sisters - Dank Je Voor De Bloemen"
    # - "(The Melody Sisters) Dank Je Voor De Bloemen"
    #
    # Intentionally conservative: refuses prefixes that contain guest keywords (feat/with/etc.).
    # Allows optional whitespace around separators and optional bracket wrappers around the artist name.

    # 1) Bracket-wrapped artist prefix, optionally followed by a dash separator:
    #    "(Artist) Title", "[Artist] Title", "{Artist} Title", and also "(Artist)- Title", etc.
    $patternBracket = "^\s*[\(\[\{]\s*(?<p>[^\)\]\}]+?)\s*[\)\]\}]\s*(?:[-–—]\s*)?(?<r>.+?)\s*$"
    $mb = [regex]::Match($title, $patternBracket, "IgnoreCase")
    if ($mb.Success) {
        $prefixB = Cleanup-Whitespace $mb.Groups["p"].Value
        if (-not [string]::IsNullOrWhiteSpace($prefixB)) {
            if (-not ([regex]::IsMatch($prefixB, "\b(?:feat\.?|ft\.?|featuring|with|met|mit|con|avec|com|w\/|&)\b", "IgnoreCase"))) {
                if (GuestIsAlreadyCreditedInArtist $artist $prefixB) {
                    $restB = Cleanup-Whitespace $mb.Groups["r"].Value
                    if (-not [string]::IsNullOrWhiteSpace($restB)) { return $restB }
                }
            }
        }
        return $title
    }

    # 2) Plain artist prefix with a required dash separator.
    $patternDash = "^(?<p>.+?)\s*[-–—]\s*(?<r>.+?)\s*$"
    $m = [regex]::Match($title, $patternDash, "IgnoreCase")
    if (-not $m.Success) { return $title }

    $prefix = Cleanup-Whitespace $m.Groups["p"].Value
    if ([string]::IsNullOrWhiteSpace($prefix)) { return $title }

    # Do not treat "Artist feat/with Guest - Title" as an artist-duplicate prefix.
    if ([regex]::IsMatch($prefix, "\b(?:feat\.?|ft\.?|featuring|with|met|mit|con|avec|com|w\/|&)\b", "IgnoreCase")) {
        return $title
    }

    if (-not (GuestIsAlreadyCreditedInArtist $artist $prefix)) { return $title }

    $rest = Cleanup-Whitespace $m.Groups["r"].Value
    if ([string]::IsNullOrWhiteSpace($rest)) { return $title }

    return $rest
}

function Unwrap-EnclosingArtistBrackets([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }

    # If the entire artist token is wrapped in (), [] or {}, unwrap it.
    # This is conservative and repeats a few times to handle nested wrapping like "[[Artist]]".
    $t = $s.Trim()

    for ($i = 0; $i -lt 3; $i++) {
        $m = [regex]::Match($t, '^\s*(?<open>[\(\[\{])\s*(?<inner>.*?)\s*(?<close>[\)\]\}])\s*$', 'CultureInvariant')
        if (-not $m.Success) { break }

        $open  = $m.Groups["open"].Value
        $close = $m.Groups["close"].Value
        $inner = $m.Groups["inner"].Value

        $pairOk = $false
        if ($open -eq '(' -and $close -eq ')') { $pairOk = $true }
        elseif ($open -eq '[' -and $close -eq ']') { $pairOk = $true }
        elseif ($open -eq '{' -and $close -eq '}') { $pairOk = $true }

        if (-not $pairOk) { break }

        $inner = $inner.Trim()
        if ([string]::IsNullOrWhiteSpace($inner)) { return "" }

        # Only unwrap when the inner text does not itself contain the same bracket type.
        # This prevents accidental unwrapping of strings like "[WAV] Artist [EAC]" where the outermost
        # characters happen to form a valid pair but the content clearly contains additional brackets.
        if ($open -eq '(' -and $close -eq ')' -and $inner -match '[\(\)]') { break }
        if ($open -eq '[' -and $close -eq ']' -and $inner -match '[\[\]]') { break }
        if ($open -eq '{' -and $close -eq '}' -and $inner -match '[\{\}]') { break }

        $t = $inner
    }

    return $t
}


function Get-CompareKey([string]$s) {
    return (Normalize-IdentityKey $s)
}

function Dedup-DuplicateTitle([string]$title) {
    if ([string]::IsNullOrWhiteSpace($title)) { return $title }

    $t = Cleanup-Whitespace $title
    $parts = $t -split "\s-\s"
    if ($parts.Count -lt 2) { return $t }

    $left  = ($parts[0..($parts.Count - 2)] -join " - ").Trim()
    $right = $parts[$parts.Count - 1].Trim()

    $leftKey  = Get-CompareKey ([regex]::Replace($left, "\s*[\(\[].*?[\)\]]\s*$", "").Trim())
    $rightKey = Get-CompareKey ([regex]::Replace($right,"\s*[\(\[].*?[\)\]]\s*$", "").Trim())

    if ($leftKey -and ($leftKey -eq $rightKey)) { return $left }
    return $t
}

function Dedup-AdjacentCommaArtistPrefix([string]$artist) {
    if ([string]::IsNullOrWhiteSpace($artist)) { return $artist }

    # Adjacent comma duplicate: "A, A ..." -> "A ..." (very conservative).
    $a = Cleanup-Whitespace $artist
    $comma = $a.IndexOf(',')
    if ($comma -lt 0) { return $a }

    $left = Cleanup-Whitespace ($a.Substring(0, $comma))
    $rest = Cleanup-Whitespace ($a.Substring($comma + 1))

    if ([string]::IsNullOrWhiteSpace($left) -or [string]::IsNullOrWhiteSpace($rest)) { return $a }

    # Full-segment duplicate: "A, A" -> "A" (safe; avoids false multi-artist truncation).
    $kLeft = Normalize-IdentityKey $left
    $kRest = Normalize-IdentityKey $rest
    if ($kLeft -and $kRest -and ($kLeft -eq $kRest)) {
        return $left
    }
    if ($left.Length -lt 3) { return $a }
    if (-not ($left -match "(\p{L}|\p{Nd})")) { return $a }

    # Extract the first credited artist token from the remainder.
    $m = [regex]::Match(
        $rest,
        "^(?<first>.+?)(?=\s*(?:,|&|/|;|\+|\band\b|\bfeat\.?(?=\s|$)|\bft\.?(?=\s|$)|\bfeaturing\b)\s*|$)",
        "IgnoreCase"
    )

    if (-not $m.Success) { return $a }

    $first = Cleanup-Whitespace $m.Groups["first"].Value
    if ([string]::IsNullOrWhiteSpace($first)) { return $a }

    $k1 = Normalize-NameKey $left
    $k2 = Normalize-NameKey $first

    if ($k1 -and $k2 -and ($k1 -eq $k2)) {
        return $rest
    }

    return $a
}

# -------------------- IO helpers ---------------------------------------------

function Read-TextRobust([string]$path) {
    for ($i = 0; $i -lt $ReadRetryCount; $i++) {
        try { return Get-Content -Path $path -Raw -Encoding UTF8 -ErrorAction Stop }
        catch {
            try { return Get-Content -Path $path -Raw -Encoding Default -ErrorAction Stop }
            catch { Start-Sleep -Milliseconds $ReadRetryDelayMs }
        }
    }
    return ""
}

function Read-NowPlayingStable([string]$path) {
    $maxWaitMs = 1500
    $stepMs = 50
    $tries = [Math]::Max(1, [int]($maxWaitMs / $stepMs))

    for ($i = 0; $i -lt $tries; $i++) {
        $raw = Read-TextRobust $path
        if ($null -eq $raw) { $raw = "" }

        $raw2 = ($raw -replace "^\uFEFF", "")
        $raw2 = $raw2.Trim()
        if ([string]::IsNullOrWhiteSpace($raw2)) { return "" }
        if ($raw2.IndexOf($SepChar) -lt 0) { return $raw }

        $parts = $raw2 -split [regex]::Escape($SepChar), 2
        if ($parts.Count -ge 2) {
            $a = $parts[0]
            $t = $parts[1]
            if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($t)) { return $raw }
            return $raw
        }

        Start-Sleep -Milliseconds $stepMs
    }

    return (Read-TextRobust $path)
}

function Write-Utf8NoBomAtomic([string]$path, [string]$text, [string]$tmpName) {
    # Atomic UTF-8 (no BOM) write: write to temp file in same directory, then move over the destination.
    # Returns $true on success, $false on failure (and stores the error message in $script:LastWriteError).
    $script:LastWriteError = $null

    try {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        $tmp = Join-Path $dir $tmpName

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmp, $text, $utf8NoBom)
        Move-Item -Force -Path $tmp -Destination $path -ErrorAction Stop
        return $true
    } catch {
        try { if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue | Out-Null } } catch { }
        try { $script:LastWriteError = $_.Exception.Message } catch { $script:LastWriteError = "Write failed." }
        return $false
    }
}

function Write-OutputsAtomic([string]$rtText, [string]$rtPlusText, [string]$prefixText) {
    if ([string]::IsNullOrEmpty($rtText)) {
        # Suppress boolean return values from the atomic writer to avoid accidental UI corruption.
        $null = Write-Utf8NoBomAtomic $PrefixFile "" ".nowplaying_prefix.tmp"
        $null = Write-Utf8NoBomAtomic $OutFileRt "" ".nowplaying_rt.tmp"
        $null = Write-Utf8NoBomAtomic $OutFileRtPlus "" ".nowplaying_rtplus.tmp"
    } else {
        # Suppress boolean return values from the atomic writer to avoid accidental UI corruption.
        $null = Write-Utf8NoBomAtomic $PrefixFile $prefixText ".nowplaying_prefix.tmp"
        $null = Write-Utf8NoBomAtomic $OutFileRt $rtText ".nowplaying_rt.tmp"
        $null = Write-Utf8NoBomAtomic $OutFileRtPlus $rtPlusText ".nowplaying_rtplus.tmp"
    }
}

function Hard-TruncateFileUtf8NoBom([string]$path) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $fs = $null
    $sw = $null
    try {
        $fs = New-Object System.IO.FileStream(
            $path,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::ReadWrite
        )
        $sw = New-Object System.IO.StreamWriter($fs, $utf8NoBom)
        $sw.Write("")
        $sw.Flush()
    } finally {
        if ($sw) { $sw.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}

function Clear-OutputsFast {
    try { Hard-TruncateFileUtf8NoBom $PrefixFile } catch { }
    try { Hard-TruncateFileUtf8NoBom $OutFileRt } catch { }
    try { Hard-TruncateFileUtf8NoBom $OutFileRtPlus } catch { }
}

# -------------------- Content fixes ------------------------------------------

function Fix-ApostropheSuffixCase([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }

    $chars = $s.ToCharArray()
    for ($i = 0; $i -lt ($chars.Length - 1); $i++) {
        if ($chars[$i] -ne "'") { continue }
        $next = $chars[$i + 1]
        if (-not [char]::IsUpper($next)) { continue }

        $afterIndex = $i + 2
        if ($afterIndex -lt $chars.Length) {
            $after = $chars[$afterIndex]
            if ([char]::IsLower($after)) { continue }
        }
        $chars[$i + 1] = [char]::ToLowerInvariant($next)
    }
    return -join $chars
}

function Strip-Trailing-Brackets([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }

    # Under length pressure, we normally drop a trailing bracket group to save space.
    # However, for acronym-style titles we prefer keeping the descriptive expansion.
    # Example:
    #   "T.S.O.P. (The Sound Of Philadelphia)" -> "The Sound Of Philadelphia"
    # This is intentionally conservative and only triggers when:
    # - The bracket group is trailing, and
    # - The head looks like a short all-caps acronym (optionally dotted), and
    # - The bracket content looks like a real title (contains letters and a space).
    $t = $s.Trim()
    $m = [regex]::Match($t, '^(?<head>.+?)\s*[\(\[]\s*(?<inner>[^)\]]+?)\s*[\)\]]\s*$', 'IgnoreCase')
    if ($m.Success) {
        $head  = ($m.Groups['head'].Value).Trim()
        $inner = ($m.Groups['inner'].Value).Trim()

        if (-not [string]::IsNullOrWhiteSpace($head) -and -not [string]::IsNullOrWhiteSpace($inner)) {
            $innerHasWords = ($inner -match '(\p{L}|\p{Nd})') -and ($inner -match '\s')
            if ($innerHasWords) {
                $headCompact = [regex]::Replace($head, '\s+', '')
                $headNoDots  = [regex]::Replace($headCompact, '\.', '')

                $isAcronymDotted = ($headCompact -match '^[A-Z0-9\.]{2,15}$') -and ($headCompact -match '\.') -and ($headNoDots -match '^[A-Z0-9]{2,8}$')
                $isAcronymPlain  = ($headNoDots -match '^[A-Z0-9]{2,6}$') -and ($headCompact -match '^[A-Z0-9\.]{2,8}$')

                if ($isAcronymDotted -or $isAcronymPlain) {
                    return $inner
                }
            }
        }
    }

    return ([regex]::Replace($t, "\s*[\(\[].*?[\)\]]\s*$", "")).Trim()
}

function Strip-FeatTail([string]$s) {
    return ([regex]::Replace($s, "(?:\s+|\s*[-–—]\s*)(feat\.?|ft\.?|featuring)\s+.*$", "", "IgnoreCase")).Trim()
}

function Compact-FeatTailToAmp([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }

    # Ensure we don't match "feat" inside "featuring".
    $pattern = "\s*(?:[\(\[]\s*)?(?:(?:featuring)\b|(?:feat|ft)\.?\b)\s*(?<g>[^)\]]+?)(?:\s*[\)\]])?\s*$"
    $m = [regex]::Match($s, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return $s }

    $guest = $m.Groups["g"].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($guest)) { return $s }

    $head = $s.Substring(0, $m.Index).TrimEnd()
    return ("$head & $guest").Trim()
}

function Strip-SoundtrackTail([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Strip film/soundtrack context tails that are commonly appended after a strong separator.
    # This is intentionally conservative: it only triggers when the suffix starts with
    # explicit keywords such as "Theme from" or "From the film/motion picture/soundtrack".
    $sep = "(?:-|–|—)"

    $t1 = [regex]::Replace(
        $t,
        "\s*${sep}\s*(?:Theme\s+from)\s+(?:'[^']+'|""[^""]+""|[^\r\n]+?)\s*$",
        "",
        "IgnoreCase"
    ).Trim()
    if ($t1 -ne $t -and -not [string]::IsNullOrWhiteSpace($t1)) { return $t1 }

    # Also strip parenthesized "Theme from ..." tails when they appear as a trailing bracket group,
    # e.g. "My Heart Will Go On (Love Theme From Titanic)". This only triggers at the very end.
    $t1b = [regex]::Replace(
        $t,
        "\s*[\(\[]\s*(?:(?:Love|Main)\s+)?Theme\s+From\s+[^)\]]+[\)\]]\s*$",
        "",
        "IgnoreCase"
    ).Trim()
    if ($t1b -ne $t -and -not [string]::IsNullOrWhiteSpace($t1b)) { return $t1b }

    $t1b = [regex]::Replace(
        $t,
        "\s*${sep}\s*(?:From\s+(?:the\s+)?(?:film|movie|motion\s+picture|soundtrack|original\s+soundtrack|original\s+motion\s+picture\s+soundtrack|ost))\b[^\r\n]*$",
        "",
        "IgnoreCase"
    ).Trim()
    if ($t1b -ne $t -and -not [string]::IsNullOrWhiteSpace($t1b)) { return $t1b }

    $t2 = [regex]::Replace(
        $t,
        "\s*-\s*From\s+""[^""]+""\s*(?:Soundtrack|\bOST\b|Original\s+Motion\s+Picture\s+Soundtrack)?\s*$",
        "",
        "IgnoreCase"
    ).Trim()
    if ($t2 -ne $t -and -not [string]::IsNullOrWhiteSpace($t2)) { return $t2 }

    $t3 = [regex]::Replace(
        $t,
        "\s*[\(\[]\s*[^)\]]*(?:Soundtrack|\bOST\b|Original\s+Motion\s+Picture\s+Soundtrack)\s*[^)\]]*[\)\]]\s*$",
        "",
        "IgnoreCase"
    ).Trim()
    if ($t3 -ne $t -and -not [string]::IsNullOrWhiteSpace($t3)) { return $t3 }

    $t4 = [regex]::Replace(
        $t,
        "\s*-\s*.+\s+(?:Soundtrack|\bOST\b|Original\s+Motion\s+Picture\s+Soundtrack)\s*$",
        "",
        "IgnoreCase"
    ).Trim()
    if ($t4 -ne $t -and -not [string]::IsNullOrWhiteSpace($t4)) { return $t4 }

    return $t
}

function Strip-RemasterTail([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Multilingual "remaster" markers (kept conservative; only used for trailing suffix stripping).
    $remKw = "(?:remaster(?:ed)?|remasteris(?:e|é)(?:e|d)?|remasteriz(?:ed)?|remasterizad[oa]|remasterizat[oa]|remasterizzat[oa]|remasterisiert)"

    $optYear = "(?:\s*[\(\[]\s*(?:19|20)\d{2}\s*[\)\]])?"

    # Require whitespace around dash/colon separators to avoid matching hyphenated words inside titles.
    $sepDash = "(?:\s+[-:]\s*|\s*[-:]\s+)"

    $t2 = [regex]::Replace(
        $t,
        "\s*[\(\[]\s*[^)\]]*\b$remKw\b[^)\]]*[\)\]]$optYear\s*$",
        "",
        "IgnoreCase"
    ).Trim()
    if ($t2 -ne $t -and -not [string]::IsNullOrWhiteSpace($t2)) { return $t2 }

    $t3 = [regex]::Replace(
        $t,
        "$sepDash[^\r\n]*\b$remKw\b[^\r\n]*$optYear\s*$",
        "",
        "IgnoreCase"
    ).Trim()
    if ($t3 -ne $t -and -not [string]::IsNullOrWhiteSpace($t3)) { return $t3 }

    $t4 = [regex]::Replace(
        $t,
        "\s*\b(?:\d{4}\s*)?(?:digital\s*)?\b$remKw\b$optYear\s*$",
        "",
        "IgnoreCase"
    ).Trim()
    if ($t4 -ne $t -and -not [string]::IsNullOrWhiteSpace($t4)) { return $t4 }

    return $t
}

function Strip-LanguageTagTail([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Remove standalone language tags like "(Dutch)" that are typically metadata, not part of the title.
    # Conservative: only removes if the bracket content is exactly one language word, and only when it
    # appears at the end of the string or right before a clear separator tail (" - ...", " : ...").
    $langs = "(?:dutch|english|german|french|spanish|italian|portuguese|polish|czech|slovak|hungarian|swedish|norwegian|danish|finnish|icelandic|greek|turkish|arabic|hebrew|japanese|chinese|korean|russian|ukrainian)"
    $sep   = "(?:\s+[-–—:]\s+|\s+[-–—:]\s*|\s*[-–—:]\s+)"  # requires whitespace on at least one side

    $t2 = [regex]::Replace(
        $t,
        "\s*[\(\[]\s*\b$langs\b\s*[\)\]](?=\s*$|$sep)",
        "",
        "IgnoreCase"
    ).Trim()

    if ($t2 -and $t2 -ne $t) { return $t2 }
    return $t
}

function Strip-TitleWhitelistTails([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    $kw = "(?:deluxe\s+edition|bonus\s+track|album\s+version|explicit|clean)"
    $optYear = "(?:\s*[\(\[]\s*(?:19|20)\d{2}\s*[\)\]])?"

    $t2 = [regex]::Replace(
        $t,
        "\s*[\(\[]\s*[^)\]]*\b$kw\b[^)\]]*[\)\]]$optYear\s*$",
        "",
        "IgnoreCase"
    ).Trim()
    if ($t2 -ne $t -and -not [string]::IsNullOrWhiteSpace($t2)) { return $t2 }

    $t3 = [regex]::Replace(
        $t,
        "\s*[-:]\s*[^\r\n]*\b$kw\b[^\r\n]*$optYear\s*$",
        "",
        "IgnoreCase"
    ).Trim()
    if ($t3 -ne $t -and -not [string]::IsNullOrWhiteSpace($t3)) { return $t3 }

    return $t
}

function Strip-VersionMixTail([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    $kw = "(?:radio\s+edit|edit|single\s+version|extended\s+(?:mix|version)|club\s+mix|dub(?:\s+mix)?|instrumental|acoustic|acoustical|remix|mix|version)"
    $optYear = "(?:\s*[\(\[]\s*(?:19|20)\d{2}\s*[\)\]])?"

    # Require whitespace around dash/colon separators to avoid matching hyphenated words inside titles.
    $sepDash = "(?:\s+[-:]\s*|\s*[-:]\s+)"

    $t2 = [regex]::Replace(
        $t,
        "\s*[\(\[]\s*[^)\]]*\b$kw\b[^)\]]*[\)\]]$optYear\s*$",
        "",
        "IgnoreCase"
    ).Trim()
    if ($t2 -ne $t -and -not [string]::IsNullOrWhiteSpace($t2)) { return $t2 }

    $t3 = [regex]::Replace(
        $t,
        "$sepDash[^\r\n]*\b$kw\b[^\r\n]*$optYear\s*$",
        "",
        "IgnoreCase"
    ).Trim()
    if ($t3 -ne $t -and -not [string]::IsNullOrWhiteSpace($t3)) { return $t3 }

    $t4 = [regex]::Replace(
        $t,
        "\s+\b$kw\b$optYear\s*$",
        "",
        "IgnoreCase"
    ).Trim()
    if ($t4 -ne $t -and -not [string]::IsNullOrWhiteSpace($t4)) { return $t4 }

    return $t
}

function Strip-LowPriorityDashSuffix([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Under length pressure, drop low-priority trailing context after a dash.
    # Examples:
    #   "Run to Me - Live @Ahoy"        -> "Run to Me"  (handled earlier; kept here as an example)
    #   "Song Title – Acoustic Session" -> "Song Title"
    # This is intentionally conservative: it only triggers when the suffix starts with a dash and a known keyword.
    $kw = "(?:live|acoustic|acoustical|acoustique|akustisch|unplugged|session|studio(?:\s*(?:version|versie|versión|versione|versao|versão))?)"
    $t2 = [regex]::Replace($t, "\s*[-–—]\s*\b$kw\b.*$", "", "IgnoreCase").Trim()

    if ($t2 -and $t2 -ne $t) { return $t2 }
    return $t
}

function Strip-LiveDashSuffixAlways([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Always drop trailing " - Live ..." style suffixes from titles.
    # Rationale: the listener can hear that a track is live; the suffix is usually low-value metadata.
    # Examples:
    #   "Run to Me - Live @Ahoy"        -> "Run to Me"
    #   "Song Title – Live at Wembley" -> "Song Title"
    #
    # This is intentionally narrow: it only triggers when "live" is introduced by a dash separator.
    $t2 = [regex]::Replace($t, "\s*[-–—]\s*(?:live|(?:mtv\s+)?unplugged)\b.*$", "", "IgnoreCase").Trim()

    if ($t2 -and $t2 -ne $t) { return $t2 }
    return $t
}

function Strip-LiveBracketSuffixAlways([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Always drop trailing "(Live ...)" or "[Live ...]" style suffixes from titles.
    # Rationale: the listener can hear that a track is live; the suffix is usually low-value metadata.
    #
    # Note: Some tags contain nested parentheses inside the Live tail, e.g. "(Live @Ahoy(2009))".
    # A plain "[^)]*" match would fail in that case, so we handle:
    #   - Square brackets with a simple (non-nested) match, and
    #   - Parentheses with a .NET balancing-group pattern that supports nesting.

    # Case 1: trailing "[Live ...]" (no nesting support needed).
    $t = [regex]::Replace(
        $t,
        "\s*\[\s*(?:live|(?:mtv\s+)?unplugged)\b[^\]]*\]\s*$",
        "",
        "IgnoreCase"
    )

    # Case 1b: trailing "{Live ...}" or "{Unplugged ...}" (no nesting support needed).
    $t = [regex]::Replace(
        $t,
        "\s*\{\s*(?:live|(?:mtv\s+)?unplugged)\b[^}]*\}\s*$",
        "",
        "IgnoreCase"
    )

    # Case 2: trailing "(Live ...)" with possible nested parentheses.
    $t = [regex]::Replace(
        $t,
        "\s*\(\s*(?:live|(?:mtv\s+)?unplugged)\b(?>[^()]+|\((?<d>)|\)(?<-d>))*(?(d)(?!))\)\s*$",
        "",
        "IgnoreCase"
    )

    return (Cleanup-Whitespace $t)
}

function Strip-MeaninglessTrailingSeparators([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # Remove obvious junk at the end of a string, such as a trailing dash or list separator
    # left behind after other tail-stripping operations.
    # Examples:
    # - "Run to Me -"            -> "Run to Me"
    # - "Run to Me -  "          -> "Run to Me"
    # - "Artist &"               -> "Artist"
    # - "Title , "               -> "Title"
    #
    # This is intentionally conservative: it only strips if the tail consists solely of
    # separators and whitespace (no letters/digits).

    $t = Cleanup-Whitespace $s

    $t = [regex]::Replace($t, "\s*(?:[-–—,;:/\+\|&])+\s*$", "", "IgnoreCase")

    return (Cleanup-Whitespace $t)
}

function Strip-AudioFormatTail([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    $kw = "(?:mono|stereo|stereo\s*mix|mono\s*mix)"

    $t2 = [regex]::Replace(
        $t,
        "\s*(?:[-|/]\s*)?(?:[\(\[]\s*)?\b$kw\b(?:\s*[\)\]])?\s*$",
        "",
        "IgnoreCase"
    ).Trim()

    if ($t2 -and $t2 -ne $t) { return $t2 }
    return $t
}

function Strip-LiveLocationTail([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $t = $s.Trim()

    # Conservative stripping of trailing " - Live From/At/In ..." style suffixes.
    # Only strips when the suffix strongly looks like a venue/location tag (contains a year, comma, or slash).
    $year = "(?:19|20)\d{2}"
    $live = "(?:live\s+(?:from|at|in))"

    # Require whitespace around dash separators to avoid matching hyphenated words inside titles.
    $sepDash = "(?:\s+[-–—]\s*|\s*[-–—]\s+)"

    $t2 = [regex]::Replace(
        $t,
        "\s*[\(\[]\s*[^)\]]*\b$live\b[^)\]]*(?:\b$year\b|[,/])[^)\]]*[\)\]]\s*$",
        "",
        "IgnoreCase"
    ).Trim()
    if ($t2 -ne $t -and -not [string]::IsNullOrWhiteSpace($t2)) { return $t2 }

    $t3 = [regex]::Replace(
        $t,
        "$sepDash\b$live\b\s+.*?(?:\b$year\b|[,/].*)\s*$",
        "",
        "IgnoreCase"
    ).Trim()
    if ($t3 -ne $t -and -not [string]::IsNullOrWhiteSpace($t3)) { return $t3 }

    return $t
}
function WordCut([string]$text, [int]$limit) {
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    if ($text.Length -le $limit) { return $text }

    $cut = $text.Substring(0, $limit)
    $lastSpace = $cut.LastIndexOf(" ")
    if ($lastSpace -ge 10) { $cut = $cut.Substring(0, $lastSpace) }
    return $cut.Trim(" ", "-", "_", ",", ";", ":")
}

function Best-TitleCut([string]$title, [int]$limit) {
    if ([string]::IsNullOrWhiteSpace($title)) { return "" }
    if ($limit -le 0) { return "" }
    if ($title.Length -le $limit) { return $title }

    $wc = WordCut $title $limit

    # When a very long unbroken token exists, WordCut may stop too early.
    # In that case, prefer a filled cut (mid-token) and let Trim-ForEllipsis
    # clean up the end before we add an ellipsis.
    $sub = $title.Substring(0, [Math]::Min($title.Length, $limit))
    $sub = Trim-ForEllipsis $sub

    if (-not [string]::IsNullOrWhiteSpace($sub) -and $sub.Length -ge 8 -and $sub.Length -gt $wc.Length) {
        return $sub
    }

    return $wc
}

function Trim-ForEllipsis([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # Remove trailing characters that are very unlikely to be a meaningful end of a title.
    # This intentionally strips whitespace, punctuation and symbols (slashes, dashes, quotes, etc.).
    $t = $s.TrimEnd()

    # If we ended up with a tiny fragment after a hard separator (e.g. " / Li"),
    # drop that fragment so we don't send a dangling tail before the ellipsis.
    # This is intentionally conservative and only targets the slash separator.
    $t = [regex]::Replace($t, "\s*/\s*[\p{L}\p{Nd}]{1,4}$", "").TrimEnd()
    # Also treat a strong dash tail (" - Mo") like a tiny fragment and drop it before ellipsis.
    $t = [regex]::Replace($t, "\\s*(?:-|–|—)\\s*[\\p{L}\\p{Nd}]{1,6}$", "").TrimEnd()
    $t = [regex]::Replace($t, "[\s\p{P}\p{S}]+$", "").TrimEnd()

    # Safety: never return an empty string here if there were any letters/digits.
    if ([string]::IsNullOrWhiteSpace($t)) { return "" }
    return $t
}

function Looks-LikeMultiArtist([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    return [regex]::IsMatch($s, "(?:,|&|/|\+|\band\b|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b)", "IgnoreCase")
}

function Fit-ArtistPreserveTitle([string]$artistOriginal, [string]$artistCandidate, [string]$title, [int]$maxLen, [string]$joiner) {
    $artistOriginal  = Cleanup-Whitespace $artistOriginal
    $artistCandidate = Cleanup-Whitespace $artistCandidate
    $title           = Cleanup-Whitespace $title

    if (-not $artistCandidate -or -not $title) { return $null }

    $base = "$artistCandidate$joiner$title"
    if ($base.Length -le $maxLen) { return $base }

    # Preserve the full title and squeeze artist into the remaining budget.
    $roomForArtist = $maxLen - $joiner.Length - $title.Length
    if ($roomForArtist -lt 1) { return $null }

    # If preserving the full title would force us to cut even the first credited artist
    # mid-name, skip this strategy and let the later truncation logic shorten the title
    # instead (including graceful ellipsis inside long unbroken tokens).
    $minDesiredArtist = $null
    try {
        $rxFirst = New-Object System.Text.RegularExpressions.Regex(
            "\s*(?:,|&|/|;|\+|\band\b|\bfeat\.?(?=\s|$)|\bft\.?(?=\s|$)|\bfeaturing\b)\s*",
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        foreach ($p in $rxFirst.Split($artistCandidate)) {
            $n = Cleanup-Whitespace $p
            if (-not [string]::IsNullOrWhiteSpace($n)) { $minDesiredArtist = $n; break }
        }
    } catch { $minDesiredArtist = $null }

    if (-not [string]::IsNullOrWhiteSpace($minDesiredArtist)) {
        if (Looks-LikeMultiArtist $artistOriginal) {
            $minDesiredArtist = (Cleanup-Whitespace ($minDesiredArtist + "..."))
        }
        if ($roomForArtist -lt $minDesiredArtist.Length) {
            return $null
        }
    }

    $suffix = "..."
    $wantSuffix = (Looks-LikeMultiArtist $artistOriginal)

    $artistBudget = $roomForArtist
    if ($wantSuffix -and ($artistBudget -gt $suffix.Length + 1)) {
        $artistBudget -= $suffix.Length
    } else {
        $wantSuffix = $false
    }

    if ($artistBudget -lt 1) { return $null }

    # If we have multiple credited artists and we need to squeeze, try to keep as many
    # *complete* artist names as possible ("A, B et al."), before falling back to just
    # the first credited artist ("A et al."). This avoids overly aggressive shortening
    # when there is still plenty of room.
    if ($wantSuffix) {
        $parts = @()
        try {
            $rxSplit = New-Object System.Text.RegularExpressions.Regex(
                "\s*(?:,|&|/|;|\+|\band\b|\bfeat\.?(?=\s|$)|\bft\.?(?=\s|$)|\bfeaturing\b)\s*",
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
            foreach ($p in $rxSplit.Split($artistCandidate)) {
                $n = Cleanup-Whitespace $p
                if (-not [string]::IsNullOrWhiteSpace($n)) { $parts += $n }
            }
        } catch { $parts = @() }

        if ($parts.Count -ge 2) {
            # Prefer the maximum number of full names that still fits within the budget.
            for ($k = $parts.Count - 1; $k -ge 1; $k--) {
                $prefix = ($parts[0..($k-1)] -join ", ")
                $cand = (Cleanup-Whitespace ($prefix + $suffix))
                if ($cand.Length -le $roomForArtist) {
                    $out = "$cand$joiner$title"
                    if ($out.Length -le $maxLen) { return $out }
                }
            }

            # Also allow the single-artist (no suffix) form as a last-ditch fallback.
            $first = $parts[0]
            if (-not [string]::IsNullOrWhiteSpace($first)) {
                if ((Cleanup-Whitespace ($first + $suffix)).Length -le $roomForArtist) {
                    $out = "$(Cleanup-Whitespace ($first + $suffix))$joiner$title"
                    if ($out.Length -le $maxLen) { return $out }
                }
                if ($first.Length -le $roomForArtist) {
                    $out = "$first$joiner$title"
                    if ($out.Length -le $maxLen) { return $out }
                }
            }
        } elseif ($parts.Count -eq 1) {
            $first = $parts[0]
            if (-not [string]::IsNullOrWhiteSpace($first)) {
                if ((Cleanup-Whitespace ($first + $suffix)).Length -le $roomForArtist) {
                    $out = "$(Cleanup-Whitespace ($first + $suffix))$joiner$title"
                    if ($out.Length -le $maxLen) { return $out }
                }
                if ($first.Length -le $roomForArtist) {
                    $out = "$first$joiner$title"
                    if ($out.Length -le $maxLen) { return $out }
                }
            }
        }
    }

    $aCut = WordCut $artistCandidate $artistBudget
    if ([string]::IsNullOrWhiteSpace($aCut)) { return $null }

    $outArtist = $aCut
    if ($wantSuffix -and ($aCut.Length -lt $artistCandidate.Length)) {
        $outArtist = (Cleanup-Whitespace ($aCut + $suffix))
    }

    $out = "$outArtist$joiner$title"
    if ($out.Length -le $maxLen) { return $out }

    return $null
}

function Smart-Truncate-Fields([string]$artist, [string]$title, [int]$maxLen, [string]$joiner) {
    if ($null -eq $artist) { $artist = "" }
    if ($null -eq $title)  { $title  = "" }

    $artist = $artist.Trim()
    $title  = $title.Trim()

    $base = ""
    if ($artist -and $title) { $base = "$artist$joiner$title" }
    elseif ($artist) { $base = $artist }
    else { $base = $title }

    if ($base.Length -le $maxLen) { return $base }

    # First attempt: compact trailing feat tails to "& Guest".
    $aC = Compact-FeatTailToAmp $artist
    $tC = Compact-FeatTailToAmp $title

    $baseC = ""
    if ($aC -and $tC) { $baseC = "$aC$joiner$tC" }
    elseif ($aC) { $baseC = $aC }
    else { $baseC = $tC }

    if ($baseC.Length -le $maxLen) { return $baseC }

    # Second attempt:
    # - For title: strip a trailing feat tail (if any).
    # - Do NOT remove bracketed subtitle tails here. Those can be meaningful (e.g. "(The Postman Song)"),
    #   and they should only be dropped as a late length-pressure fallback.
    # - For artist: do not strip anything at this stage.
    $a2 = $artist
    $t2 = Strip-FeatTail $title

    $base2 = ""
    if ($a2 -and $t2) { $base2 = "$a2$joiner$t2" }
    elseif ($a2) { $base2 = $a2 }
    else { $base2 = $t2 }

    if ($base2.Length -le $maxLen) { return $base2 }

    # Third attempt: remove common version/mix suffixes from title.
    $t3 = Strip-VersionMixTail $t2
    if ($t3 -ne $t2 -and -not [string]::IsNullOrWhiteSpace($t3)) {
        $base3 = ""
        if ($a2 -and $t3) { $base3 = "$a2$joiner$t3" }
        elseif ($a2) { $base3 = $a2 }
        else { $base3 = $t3 }

        if ($base3.Length -le $maxLen) { return $base3 }

        $t2 = $t3
        $base2 = $base3
    }

    # Fourth attempt (length pressure): drop low-priority dash suffixes from the title (e.g. "- Live @Venue")
    # before we start collapsing multi-artist credits to "et al.".
    $tLP = Strip-LowPriorityDashSuffix $t2
    if ($tLP -ne $t2 -and -not [string]::IsNullOrWhiteSpace($tLP)) {
        $baseLP = ""
        if ($a2 -and $tLP) { $baseLP = "$a2$joiner$tLP" }
        elseif ($a2) { $baseLP = $a2 }
        else { $baseLP = $tLP }

        if ($baseLP.Length -le $maxLen) { return $baseLP }

        # Even if we still don't fit, keep the shorter title for later truncation steps.
        $t2 = $tLP
        $base2 = $baseLP
    }

    # Late fallback before aggressive truncation:
    # - Drop trailing bracket groups from title/artist ONLY under length pressure.
    # This preserves meaningful subtitles whenever possible.
    $aB = Strip-Trailing-Brackets $artist
    $tB = Strip-Trailing-Brackets $t2

    $baseB = ""
    if ($aB -and $tB) { $baseB = "$aB$joiner$tB" }
    elseif ($aB) { $baseB = $aB }
    else { $baseB = $tB }

    if ($baseB.Length -le $maxLen) { return $baseB }

    # Keep the shorter variants for subsequent steps.
    $artist = $aB
    $t2     = $tB

    # Prefer preserving at least the first credited artist name (optionally with "et al.")
    # and truncate the title instead of cutting the artist mid-name.
    # Example:
    #   "Diana Ross, Michael Jackson, ...␟Liberation Agitato / A Brand New Day / Liberation Ballet"
    # becomes:
    #   "Diana Ross et al. - Liberation Agitato / A Brand New Day..."

    # Extra safe attempt: preserve full title if it fits, and only squeeze artist (optional "et al.").
    # This must run *before* the aggressive multi-artist fallback below, so that we don't unnecessarily
    # collapse to only the first credited artist when two (or more) would still fit within the 64-char RT limit.
    $keepTitle = Fit-ArtistPreserveTitle $artist $a2 $t2 $maxLen $joiner
    if ($keepTitle) { return $keepTitle }
    $multi = (Looks-LikeMultiArtist $artist)
    if ($multi -and $a2 -and $t2) {
        $firstArtist = $null
        try {
            $rxFirst = New-Object System.Text.RegularExpressions.Regex(
                "\s*(?:,|&|/|;|\+|\band\b|\bfeat\.?(?=\s|$)|\bft\.?(?=\s|$)|\bfeaturing\b)\s*",
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
            foreach ($p in $rxFirst.Split($a2)) {
                $n = Cleanup-Whitespace $p
                if (-not [string]::IsNullOrWhiteSpace($n)) { $firstArtist = $n; break }
            }
        } catch { $firstArtist = $null }

        $candidates = @()
        if (-not [string]::IsNullOrWhiteSpace($firstArtist)) {
            $candidates += (Cleanup-Whitespace ($firstArtist + "..."))
            $candidates += $firstArtist
        }

        foreach ($aTry in $candidates) {
            if ([string]::IsNullOrWhiteSpace($aTry)) { continue }
            $fixed = "$aTry$joiner"
            $roomForTitle = $maxLen - $fixed.Length
            if ($roomForTitle -ge 8) {
                $tCut = WordCut $t2 $roomForTitle
                if (-not [string]::IsNullOrWhiteSpace($tCut)) {
                    $out = (Cleanup-Whitespace ($fixed + $tCut))

                    # Only return without ellipsis if the title was NOT truncated.
                    if ($tCut.Length -ge $t2.Length -and $out.Length -le $maxLen) { return $out }

                    # If we had to cut, use an ellipsis.
                    $ellipsis = "..."
                    $room2 = $maxLen - $fixed.Length - $ellipsis.Length
                    if ($room2 -ge 8) {
                        $tCut2 = Best-TitleCut $t2 $room2
                        $tCut2 = Trim-ForEllipsis $tCut2
                        if ([string]::IsNullOrWhiteSpace($tCut2) -and $room2 -gt 0) {
                            $tCut2 = Trim-ForEllipsis ($t2.Substring(0, [Math]::Min($t2.Length, $room2)))
                        }
                        if (-not [string]::IsNullOrWhiteSpace($tCut2)) {
                            $out2 = (Cleanup-Whitespace ($fixed + $tCut2 + $ellipsis))
                            if ($out2.Length -le $maxLen) { return $out2 }
                        }
                    }
                }
            }
        }
    }

    # Final attempt: ellipsize with word boundary preference.
    $ellipsis = "..."
    $limitTotal = [Math]::Max(0, $maxLen - $ellipsis.Length)

    if ($a2 -and $t2) {
        $fixed = "$a2$joiner"
        $roomForTitle = $limitTotal - $fixed.Length
        if ($roomForTitle -gt 5) {
            $tCut = WordCut $t2 $roomForTitle
            $tCut = Trim-ForEllipsis $tCut
            if ([string]::IsNullOrWhiteSpace($tCut) -and $roomForTitle -gt 0) {
                $tCut = Trim-ForEllipsis ($t2.Substring(0, [Math]::Min($t2.Length, $roomForTitle)))
            }
            $out = ($fixed + $tCut + $ellipsis).Trim()
            if ($out.Length -le $maxLen) { return $out }
        }
    }

    $one = $base2
    $oneCut = WordCut $one $limitTotal
    if ($oneCut.Length -lt 3 -and $limitTotal -gt 0) {
        $oneCut = $one.Substring(0, $limitTotal).Trim()
    }
    $oneCut = Trim-ForEllipsis $oneCut
    if ([string]::IsNullOrWhiteSpace($oneCut) -and $limitTotal -gt 0) {
        $oneCut = Trim-ForEllipsis ($one.Substring(0, [Math]::Min($one.Length, $limitTotal)))
    }
    return ($oneCut + $ellipsis)
}

function Has-LettersOrDigits([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    return ($s -match "(\p{L}|\p{Nd})")
}

function Split-VisibleRtToArtistTitle([string]$visibleRt) {
    $t = Cleanup-Whitespace $visibleRt
    $parts = $t -split "\s-\s", 2
    if ($parts.Count -eq 2) {
        $a = $parts[0].Trim()
        $b = $parts[1].Trim()
        if ($a -and $b) { return [pscustomobject]@{ Artist = $a; Title = $b } }
    }
    return $null
}

function Build-VisibleRtText([string]$artist, [string]$title) {
    # If the title becomes empty (e.g. transliteration disabled and the title is entirely non-Latin),
    # fall back to an artist-only RT rather than outputting nothing.
    if (-not (Has-LettersOrDigits $title)) {
        $rt = Cleanup-Whitespace $artist
        $rt = Fix-ApostropheSuffixCase $rt
        $rt = Strip-AlwaysRemoveNoiseTags $rt
        $rt = Filter-ToRdsLatin $rt
        $rt = Strip-AlwaysRemoveNoiseTags $rt
    $rt = Cleanup-DanglingArtistSeparators $rt
        if (-not (Has-LettersOrDigits $rt)) { return "" }
        if ($rt.Length -gt $MaxLen) {
            $rt = $rt.Substring(0, $MaxLen).Trim()
            $rt = Filter-ToRdsLatin $rt
            $rt = Strip-AlwaysRemoveNoiseTags $rt
            $rt = Cleanup-DanglingArtistSeparators $rt
            if (-not (Has-LettersOrDigits $rt)) { return "" }
        }
        return $rt
    }

    $rt = Smart-Truncate-Fields $artist $title $MaxLen $OutJoin
    $rt = Cleanup-Whitespace $rt
    $rt = Fix-ApostropheSuffixCase $rt
    $rt = Strip-AlwaysRemoveNoiseTags $rt
    $rt = Filter-ToRdsLatin $rt
    $rt = Strip-AlwaysRemoveNoiseTags $rt

    if (-not (Has-LettersOrDigits $rt)) { return "" }

    if ($rt.Length -gt $MaxLen) {
        $rt = $rt.Substring(0, $MaxLen).Trim()
        $rt = Filter-ToRdsLatin $rt
        $rt = Strip-AlwaysRemoveNoiseTags $rt
        if (-not (Has-LettersOrDigits $rt)) { return "" }
    }

    return $rt
}

function Build-RtPlusOutputFromParts([string]$artist, [string]$title) {
    $a = Cleanup-Whitespace $artist
    $t = Cleanup-Whitespace $title

    # If the title is missing after filtering (e.g. transliteration disabled for a non-Latin title),
    # emit an artist-only RT+ payload instead of returning empty.
    if (-not (Has-LettersOrDigits $t)) {
        if (Has-LettersOrDigits $a) {
            $visibleArtist = Smart-Truncate-Fields $a "" $MaxLen $OutJoin
            $visibleArtist = Cleanup-Whitespace $visibleArtist
            if (-not (Has-LettersOrDigits $visibleArtist)) { return "" }
            return ("\+ar{0}\-" -f $visibleArtist)
        }
        return ""
    }

    # Title-only: emit a title-only RT+ payload.
    if (-not (Has-LettersOrDigits $a)) {
        $visibleTitle = Smart-Truncate-Fields "" $t $MaxLen $OutJoin
        $visibleTitle = Cleanup-Whitespace $visibleTitle
        if (-not (Has-LettersOrDigits $visibleTitle)) { return "" }
        return ("\+ti{0}\-" -f $visibleTitle)
    }

    $visible = Smart-Truncate-Fields $a $t $MaxLen $OutJoin

    $p = Split-VisibleRtToArtistTitle $visible
    if ($null -ne $p) {
        return ("\+ar{0}\-{1}\+ti{2}\-" -f $p.Artist, $OutJoin, $p.Title)
    }

    return ""
}

# -------------------- Country/region token helpers (RegionInfo-derived) --------------------
# Notes:
# - We use RegionInfo as the primary source for country names and ISO region codes.
# - We intentionally keep a small alias list for common non-ISO or dotted forms seen in metadata (e.g., UK, U.S.A.).
# - Sets are built once and cached in script scope for performance and consistency.
function Ensure-CountryData {
    if ($script:_CountryNameSet -and $script:_CountryIso2Set -and $script:_CountryIso3Set) { return }

    $nameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $iso2Set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $iso3Set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    try {
        foreach ($c in [System.Globalization.CultureInfo]::GetCultures([System.Globalization.CultureTypes]::SpecificCultures)) {
            try {
                $ri = New-Object System.Globalization.RegionInfo($c.Name)
                if ($ri) {
                    if (-not [string]::IsNullOrWhiteSpace($ri.EnglishName)) {
                        [void]$nameSet.Add((Cleanup-Whitespace $ri.EnglishName).Trim())
                    }
                    if (-not [string]::IsNullOrWhiteSpace($ri.TwoLetterISORegionName)) {
                        [void]$iso2Set.Add(($ri.TwoLetterISORegionName).Trim().ToUpperInvariant())
                    }
                    if (-not [string]::IsNullOrWhiteSpace($ri.ThreeLetterISORegionName)) {
                        [void]$iso3Set.Add(($ri.ThreeLetterISORegionName).Trim().ToUpperInvariant())
                    }
                }
            } catch { }
        }
    } catch { }

    # Common aliases seen in music metadata / exports.
    foreach ($a in (Get-CountryAliases)) { [void]$nameSet.Add($a) }
    # Code aliases:
    # - "UK" is commonly used in metadata but ISO-3166 alpha-2 uses "GB".
    [void]$iso2Set.Add("UK")

    $script:_CountryNameSet = $nameSet
    $script:_CountryIso2Set = $iso2Set
    $script:_CountryIso3Set = $iso3Set
}

function Test-IsCountryToken([string]$token) {
    Ensure-CountryData

    if ([string]::IsNullOrWhiteSpace($token)) { return $false }

    $x = (Cleanup-Whitespace $token).Trim()
    if ([string]::IsNullOrWhiteSpace($x)) { return $false }

    # Exact English name / alias match.
    if ($script:_CountryNameSet.Contains($x)) { return $true }

    # ISO country/region codes (safe at edges only; callers enforce clear delimiters).
    if ($x -match '^[A-Za-z]{2}$') {
        $cc2 = $x.ToUpperInvariant()
        if ($script:_CountryIso2Set.Contains($cc2)) { return $true }
    } elseif ($x -match '^[A-Za-z]{3}$') {
        $cc3 = $x.ToUpperInvariant()
        if ($script:_CountryIso3Set.Contains($cc3)) { return $true }
    }

    # Allow "The <country>" if <country> is in the set (RegionInfo typically omits the article).
    if ($x -match '^(?i)the\s+(.+)$') {
        $rest = (Cleanup-Whitespace $matches[1]).Trim()
        if (-not [string]::IsNullOrWhiteSpace($rest) -and $script:_CountryNameSet.Contains($rest)) { return $true }
    }

    # Allow dotted abbreviations like "U.S.A." by comparing without dots too.
    $xNoDots = ($x -replace '\.', '').Trim()
    if ($xNoDots -ne $x) {
        if ($script:_CountryNameSet.Contains($xNoDots)) { return $true }

        if ($xNoDots -match '^[A-Za-z]{2}$') {
            $cc2 = $xNoDots.ToUpperInvariant()
            if ($script:_CountryIso2Set.Contains($cc2)) { return $true }
        } elseif ($xNoDots -match '^[A-Za-z]{3}$') {
            $cc3 = $xNoDots.ToUpperInvariant()
            if ($script:_CountryIso3Set.Contains($cc3)) { return $true }
        }
    }

    return $false
}
# ------------------------------------------------------------------------------------------

function Remove-ArtistRegionSuffix([string]$artist) {
    if ([string]::IsNullOrWhiteSpace($artist)) { return "" }

    # Strip a trailing country/region tag that is clearly metadata and not part of the artist name.
    #
    # Supported (end of artist field only):
    # - Bracketed suffixes:  "Artist (Netherlands)", "Band [Belgium]", "Name {Japan}"
    # - Hyphen suffixes:     "Artist - Netherlands", "Band – Belgium", "Name — Japan"
    # - Country/region codes (ISO2): "Artist (US)", "Band [UK]", "Name {DE}"
    #
    # Safety rules:
    # - Only acts on a *final* token at the end of the artist field.
    # - Only strips when the token is an exact country/region name (derived from .NET RegionInfo) or a known alias,
    #   or a two-letter ISO region code (RegionInfo-derived, plus a few common aliases).
    #
    # Note: This is intentionally conservative about *what* it matches (exact token match), but broad about *which*
    #       countries are eligible (RegionInfo-derived), per our intended playlist/export use-case.

    $t = Cleanup-Whitespace $artist

    # --- 0) Lazy-build country/region name set (English names) ---
    Ensure-CountryData

    # --- 1) Two-letter country/region codes (ISO2) ---
    $m = [regex]::Match($t, '^(?<name>.+?)\s*(?:\(\s*(?<cc>[A-Z]{2})\s*\)|\[\s*(?<cc>[A-Z]{2})\s*\]|\{\s*(?<cc>[A-Z]{2})\s*\})\s*$')
    if ($m.Success) {
        $name = Cleanup-Whitespace $m.Groups["name"].Value
        $cc   = ($m.Groups["cc"].Value).ToUpperInvariant()

        if (-not [string]::IsNullOrWhiteSpace($name) -and -not [string]::IsNullOrWhiteSpace($cc)) {
            if ($script:_CountryIso2Set.Contains($cc)) { return $name }
        }

        # If it looks like a code token but is not in our allowlist, do nothing.
        return $t
    }

    # --- 2) Bracketed suffixes: (Country) / [Country] / {Country} ---
    $m2 = [regex]::Match($t, '^(?<name>.+?)\s*(?:\(\s*(?<tag>[^)\]]+?)\s*\)|\[\s*(?<tag>[^\]]+?)\s*\]|\{\s*(?<tag>[^}]+?)\s*\})\s*$')
    if ($m2.Success) {
        $name2 = Cleanup-Whitespace $m2.Groups["name"].Value
        $tag2  = Cleanup-Whitespace $m2.Groups["tag"].Value

        if (-not [string]::IsNullOrWhiteSpace($name2) -and (Test-IsCountryToken $tag2)) {
            return $name2
        }
    }

    # --- 3) Hyphen/ndash/mdash suffixes: " - Country" / " – Country" / " — Country" ---
    $m3 = [regex]::Match($t, '^(?<name>.+?)\s*[-–—]\s*(?<tag>[^-–—]+?)\s*$')
    if ($m3.Success) {
        $name3 = Cleanup-Whitespace $m3.Groups["name"].Value
        $tag3  = Cleanup-Whitespace $m3.Groups["tag"].Value

        if (-not [string]::IsNullOrWhiteSpace($name3) -and (Test-IsCountryToken $tag3)) {
            return $name3
        }
    }

    return $t
}

function Normalize-Field([string]$s) {
    $t = $s
    $t = Strip-InvisibleControls $t
    $t = Decode-BasicHtmlEntities $t
    $t = Normalize-FullwidthAscii $t
    $t = Apply-Replacements $t
    $t = Strip-AlwaysRemoveNoiseTags $t
    if ($script:TransliterationEnabled) {
        $t = Transliterate-Cyrillic $t
        $t = Transliterate-Greek $t
    }
    $t = Cleanup-Whitespace $t
    $t = Filter-ToRdsLatin $t
    $t = Strip-AlwaysRemoveNoiseTags $t
    return $t
}

function Normalize-NowPlayingParts([string]$raw) {
    if ($null -eq $raw) { return $null }

    $raw2 = $raw -replace "^\uFEFF", ""
    if ([string]::IsNullOrWhiteSpace($raw2)) { return $null }

    # Some sources (or intermediate tools) may wrap the real payload in a prefix/suffix,
    # e.g. "(03) [Artist␟Title] Artist - Title". In that case, prefer the bracketed payload
    # that contains the U+241F separator, and ignore the redundant trailing text.
    $sepEsc = [regex]::Escape([string]$SepChar)
$m = [regex]::Match($raw2, "\[([^\[\]]*${sepEsc}[^\[\]]*)\]")
if ($m.Success) { $raw2 = $m.Groups[1].Value }

# Conservative parsing: only split when the delimiter occurs exactly once.
$sepCount = 0
try { $sepCount = [regex]::Matches($raw2, $sepEsc).Count } catch { $sepCount = 0 }

if ($sepCount -eq 1) {
    $parts = $raw2 -split $sepEsc, 2
    if ($parts.Count -lt 2) { return $null }
    $artistRaw = $parts[0]
    $titleRaw  = $parts[1]
} else {
    # Title-only fallback (no split). This prevents accidental mis-parsing when the delimiter
    # is missing or appears multiple times inside titles or other payloads.
    $artistRaw = ""
    $titleRaw  = $raw2
}

    $artistRawOrig = $artistRaw

    $artistRaw = Strip-TrackNumberPrefix $artistRaw
    $artistRaw = Strip-TrackNumberPrefixLoose $artistRaw

    # If the artist field ends with an EAC rip marker that also carries a track number (e.g., "Artist - 10 (EAC)"),
    # remove that entire trailing token. This is deliberately strict: it only triggers when an explicit "(EAC)" or "[EAC]"
    # is present at the very end, and a 1–3 digit track number is attached to it.
    $artistRaw = [regex]::Replace($artistRaw, '(?i)\s*[-–—]?\s*\d{1,3}\s*[\(\[]\s*EAC\s*[\)\]]\s*$', '')
    $artistRaw = Cleanup-Whitespace $artistRaw
    $artistRaw = Unwrap-EnclosingArtistBrackets $artistRaw

    # Also handle album-like EAC tails in the *artist* field, e.g. "Artist - The Hits 2 (EAC)".
    # This is still conservative: it only triggers when "(EAC)" or "[EAC]" is at the very end AND the token
    # immediately before it is a single dash-separated segment (no additional dashes).
    $mEacAlbum = [regex]::Match($artistRaw, '(?i)^(?<name>.+?)\s*[-–—]\s*(?<tail>[^-\\r\\n]{1,80})\s*[\(\[]\s*EAC\s*[\)\]]\s*$')
    if ($mEacAlbum.Success) {
        $name = Cleanup-Whitespace $mEacAlbum.Groups["name"].Value
        $tail = Cleanup-Whitespace $mEacAlbum.Groups["tail"].Value
        if (-not [string]::IsNullOrWhiteSpace($name) -and $tail -match '[A-Za-z]') {
            $artistRaw = $name
        }
    }

    # If we previously stripped an EAC-style rip marker/track number from an "album-like" artist token,
    # we can end up with a leftover compilation segment such as " - The Hits". Remove that segment only
    # when the ORIGINAL artist field clearly contained a "The Hits" + optional volume number + optional EAC marker.
    # This is deliberately strict to avoid breaking legitimate artist names that contain " - The Hits".
    $mHits = [regex]::Match($artistRaw, '(?i)^(?<name>.+?)\s*[-–—]\s*The\s+Hits\s*$')
    if ($mHits.Success) {
        $name = Cleanup-Whitespace $mHits.Groups["name"].Value
        $orig = "$artistRawOrig"
        if ([regex]::IsMatch($orig, '(?i)\bThe\s+Hits(?:\s+\d{1,3})?\s*(?:[\(\[]\s*EAC\s*[\)\]])?\s*$')) {
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $artistRaw = $name
            }
        }
    }

    if (Is-TrackNumberOnly $artistRaw) {
        $ft2 = Try-ParseArtistTitleFromFilename $titleRaw
        if ($null -ne $ft2) {
            $artistRaw = $ft2.Artist
            $titleRaw  = $ft2.Title
        }
    }

    # Title-only inputs are allowed (e.g. "␟Pink noise..."):
    # - Title is required.
    # - Artist may be empty.
    if ([string]::IsNullOrWhiteSpace($artistRaw) -or [string]::IsNullOrWhiteSpace($titleRaw)) {
        # If the input is "Artist␟" (missing title), try to recover from a filename-like string.
        if (-not [string]::IsNullOrWhiteSpace($artistRaw) -and [string]::IsNullOrWhiteSpace($titleRaw)) {
            $ft = Try-ParseArtistTitleFromFilename $artistRaw
            if ($null -ne $ft) {
                $artistRaw = $ft.Artist
                $titleRaw  = $ft.Title
            }
        }

        # Still no title => invalid.
        if ([string]::IsNullOrWhiteSpace($titleRaw)) { return $null }

        # If artist is empty but title exists, continue (title-only).
        if ([string]::IsNullOrWhiteSpace($artistRaw)) { $artistRaw = "" }
    }

    $artist = Normalize-Field $artistRaw
    $artist = Strip-CountryPrefix $artist
    $artist = Remove-ArtistAcronymSuffix $artist
    $artist = Remove-ArtistRegionSuffix $artist
    $title  = Normalize-Field $titleRaw

    $title  = Strip-CountryPrefix $title
    $title  = Strip-CountrySuffix $title

    if ([string]::IsNullOrWhiteSpace($artist) -and [string]::IsNullOrWhiteSpace($title)) { return $null }

    # Remove version-like tails first (so "feat/with/met" stripping sees a clean title).
    $title2 = $title
    $title2 = Strip-SoundtrackTail      $title2
    $title2 = Strip-LanguageTagTail     $title2
    $title2 = Strip-RemasterTail        $title2
    $title2 = Strip-TitleWhitelistTails $title2
    $title2 = Strip-LiveDashSuffixAlways $title2
    $title2 = Strip-LiveBracketSuffixAlways $title2
    $title2 = Strip-MeaninglessTrailingSeparators $title2
    $title2 = Strip-LiveLocationTail    $title2
    $title2 = Strip-AudioFormatTail     $title2
    $title2 = Strip-VersionMixTail      $title2
    $title2 = Strip-LowPriorityDashSuffix $title2
    $title2 = Dedup-DuplicateTitle      $title2
    $title2 = Cleanup-Whitespace        $title2
    $title2 = Strip-AlwaysRemoveNoiseTags              $title2
    $title2 = Filter-ToRdsLatin         $title2
    $title2 = Strip-AlwaysRemoveNoiseTags              $title2

    $title2 = Strip-ArtistDuplicateTitlePrefix $artist $title2

    # Now perform guest-tail stripping based on the artist list (prevents duplicates).
    $title2 = Strip-FeatInTitleIfGuestsAlreadyInArtist $artist $title2
    $title2 = Strip-WithInTitleIfGuestsAlreadyInArtist $artist $title2
    $title2 = Strip-ArtistDuplicateTitleTail $artist $title2
    $title2 = Strip-MeaninglessTrailingSeparators $title2

    $title2 = Cleanup-Whitespace $title2
    $title2 = Strip-AlwaysRemoveNoiseTags       $title2
    $title2 = Filter-ToRdsLatin  $title2
    $title2 = Strip-AlwaysRemoveNoiseTags       $title2

    $artist = Cleanup-Whitespace $artist
    $artist = Strip-AlwaysRemoveNoiseTags       $artist
    $artist = Filter-ToRdsLatin  $artist
    $artist = Strip-AlwaysRemoveNoiseTags       $artist
    $artist = Dedup-AdjacentCommaArtistPrefix $artist
    $artist = Cleanup-Whitespace $artist
    $artist = Strip-AlwaysRemoveNoiseTags       $artist
    $artist = Filter-ToRdsLatin  $artist
    $artist = Strip-AlwaysRemoveNoiseTags       $artist
    $artist = Cleanup-DanglingArtistSeparators $artist
    # Title is normally required, but if the user disables transliteration a non-Latin title may be filtered away.
    # In that case, keep an artist-only output rather than forcing an empty broadcast.
    if ([string]::IsNullOrWhiteSpace($title2)) {
        if (-not [string]::IsNullOrWhiteSpace($artist)) {
            $title2 = ""
        } else {
            return $null
        }
    }

    # Artist may be empty (title-only).
    if ([string]::IsNullOrWhiteSpace($artist)) { $artist = "" }
    return [pscustomobject]@{ Artist = $artist; Title = $title2 }
}

# -------------------- Initialize persistent settings -------------------------

Load-Settings
try { Apply-DelimiterFromSettings } catch { }
# Apply persisted toggles (best-effort, robust against missing keys).
try { if ($script:Settings.ContainsKey('PrefixLanguageCode'))     { $script:PrefixLanguageCode     = "$($script:Settings['PrefixLanguageCode'])".Trim().ToUpperInvariant() } } catch { }
try { if ($script:Settings.ContainsKey('TransliterationEnabled')) { $script:TransliterationEnabled = [bool]$script:Settings['TransliterationEnabled'] } } catch { }
try { if ($script:Settings.ContainsKey('AsciiSafeEnabled'))       { $script:AsciiSafeEnabled       = [bool]$script:Settings['AsciiSafeEnabled'] } } catch { }
try { if ($script:Settings.ContainsKey('DelimiterKey') -and $script:Settings['DelimiterKey']) { $script:DelimiterKey = "$($script:Settings['DelimiterKey'])".Trim().ToUpperInvariant() } } catch { }

# Re-apply the prefix text after loading the unified settings file.
# Earlier in the script, prefix settings are initialized before Load-Settings runs.
try { Apply-PrefixFromLanguage } catch { }

# Optional: show a one-time first-run wizard for the IO directory and apply WorkDir if configured.
Show-WorkDirWizardIfNeeded
Apply-WorkDirIfConfigured

# -------------------- Watcher (Wait-Event) -----------------------------------

$watchedDir  = function Initialize-Watcher {
    # (Re)create the FileSystemWatcher so changing WorkDir takes effect immediately.
    try {
        if ($script:fsw) {
            try { $script:fsw.EnableRaisingEvents = $false } catch { }
            try { $script:fsw.Dispose() } catch { }
        }
    } catch { }

    try {
        foreach ($id in @("NP_Changed","NP_Created","NP_Renamed")) {
            try { Unregister-Event -SourceIdentifier $id -Force -ErrorAction SilentlyContinue } catch { }
        }
        try { Get-Event | Remove-Event -ErrorAction SilentlyContinue } catch { }
    } catch { }

    $script:WatchedDir  = Split-Path -Parent $InFile
    $script:WatchedName = Split-Path -Leaf  $InFile

    if (-not (Ensure-Directory $script:WatchedDir "Watcher directory")) { throw "Cannot create/access watcher directory: $script:WatchedDir" }

    $script:fsw = New-Object System.IO.FileSystemWatcher
    $script:fsw.Path = $script:WatchedDir
    $script:fsw.Filter = $script:WatchedName
    $script:fsw.IncludeSubdirectories = $false
    $script:fsw.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite, Size'
    $script:fsw.InternalBufferSize = 65536
    $script:fsw.EnableRaisingEvents = $true

    $null = Register-ObjectEvent -InputObject $script:fsw -EventName Changed -SourceIdentifier "NP_Changed"
    $null = Register-ObjectEvent -InputObject $script:fsw -EventName Created -SourceIdentifier "NP_Created"
    $null = Register-ObjectEvent -InputObject $script:fsw -EventName Renamed -SourceIdentifier "NP_Renamed"
}

$null = Ensure-WorkDirOrFallback
Initialize-Watcher

$script:LastStamp = ""

function Get-InputStamp {
    if (-not (Test-Path $InFile)) { return "" }
    try {
        $fi = Get-Item -LiteralPath $InFile -ErrorAction Stop
        return ("{0:o}|{1}" -f $fi.LastWriteTimeUtc, $fi.Length)
    } catch { return "" }
}

function Get-InputUiState {
    if (-not (Test-Path $InFile)) { return "NotAvailable" }
    try {
        $it = Get-Item -LiteralPath $InFile -ErrorAction Stop | Out-Null

        # Treat a truly empty input file as NotAvailable (requested UI behavior).
        try {
            $it = Get-Item -LiteralPath $InFile -ErrorAction Stop
            if ($it -and $it.Length -eq 0) { return "NotAvailable" }
        } catch { }

        # "Expired" is a startup-only concept: it applies only when the input file already existed at launch
        # and was older than the freshness window at that time. It must never appear later just because time passed.
        if (-not $script:HasSeenFreshInput -and $script:StartupInputWasExpired) { return "Expired" }

        # If we cannot extract valid metadata from the latest seen payload, treat the input as NotAvailable
        # even if the file physically exists (e.g., BOM-only / whitespace-only payloads from playout software).
        if (-not $script:LastMetadataValid) { return "NotAvailable" }

        return "Normal"
    } catch {
        # If the file exists but is momentarily locked during a write, keep the last known availability state.
        if ($script:LastMetadataValid) { return "Normal" }
        return "NotAvailable"
    }
}

function Should-HandleEvent($evt) {
    $args = $evt.SourceEventArgs
    if ($args.Name -ieq $script:WatchedName) { return $true }
    if ($args -is [System.IO.RenamedEventArgs]) {
        if ($args.OldName -ieq $script:WatchedName) { return $true }
    }
    return $false
}

function Compose-OutputsFromRaw([string]$raw) {
    $parts = Normalize-NowPlayingParts $raw
    if ($null -eq $parts) { return [pscustomobject]@{ Prefix = ""; Rt = ""; RtPlus = "" } }

    $visibleRt = Build-VisibleRtText $parts.Artist $parts.Title
    if ([string]::IsNullOrWhiteSpace($visibleRt)) { return [pscustomobject]@{ Prefix = ""; Rt = ""; RtPlus = "" } }

    # Prefix is selected by language; ASCII-safe mode forces the ASCII variant (diacritic-free where applicable).
    $prefixRaw = $(if ($script:AsciiSafeEnabled) { $script:PrefixTextAscii } else { $script:PrefixTextNative })

    # Keep prefix and RT/RT+ consistent: when transliteration is ON, transliterate the prefix too.
    if ($script:TransliterationEnabled) {
        $prefixRaw = Transliterate-Cyrillic $prefixRaw
        $prefixRaw = Transliterate-Greek    $prefixRaw
    }

    # Final pass selection:
    # - ASCII-safe ON: enforce the conservative Latin repertoire (diacritic-free).
    # - ASCII-safe OFF: keep Unicode (including diacritics) intact; transliteration (if enabled) still applies.
    $forceAsciiFinal = $script:AsciiSafeEnabled

    if ($forceAsciiFinal) {
        $prefix = Ensure-TrailingSpace (AsciiSafe-FinalPass $prefixRaw)
        $rt  = AsciiSafe-FinalPass $visibleRt
        $rtp = AsciiSafe-FinalPass (Build-RtPlusOutputFromParts $parts.Artist $parts.Title)
    } else {
        $prefix = Ensure-TrailingSpace (PrefixSafe-FinalPass $prefixRaw)
        $rt  = UnicodeSafe-FinalPass $visibleRt
        $rtp = UnicodeSafe-FinalPass (Build-RtPlusOutputFromParts $parts.Artist $parts.Title)
    }

    if ($rt.Length -gt $MaxLen) { $rt = (Cleanup-Whitespace ($rt.Substring(0, $MaxLen))).Trim() }

    return [pscustomobject]@{ Prefix = $prefix; Rt = $rt; RtPlus = $rtp }
}

function Do-Update {
    if ($script:Stopping) { return }

    if (Test-Path $InFile) {
        $raw = Read-NowPlayingStable $InFile
        $o = Compose-OutputsFromRaw $raw

        Write-OutputsAtomic $o.Rt $o.RtPlus $o.Prefix

        $script:LastGoodUpdate = Get-Date
        $script:HasSeenFreshInput      = $true
$script:StartupExpiredChecked = $true

        # Consider the input "not available" whenever we cannot extract valid metadata.
        # This covers BOM-only / whitespace-only inputs and malformed payloads.
        $script:LastMetadataValid = (-not [string]::IsNullOrWhiteSpace($o.Rt))

        if (-not $script:LastMetadataValid) {
            $script:LastInputUiState = "NotAvailable"
            try { Update-Status "" "" "" "" "NotAvailable" } catch { }
        } else {
            $script:LastInputUiState = "Normal"
            try { Update-Status $raw $o.Prefix $o.Rt $o.RtPlus "Normal" } catch { }
        }
    } else {
        Write-OutputsAtomic "" "" ""
        $script:LastGoodUpdate = Get-Date
        $script:LastMetadataValid = $false
        $script:LastInputUiState = "NotAvailable"
        try { Update-Status "" "" "" "" "NotAvailable" } catch { }
    }
}

function Do-UpdateIfNeeded {
    if ($script:Stopping) { return }

    $stamp = Get-InputStamp
    if ($stamp -and ($stamp -ne $script:LastStamp)) {
        $script:LastStamp = $stamp
        Do-Update
    }
}

# Ctrl+C: stop the main loop.
try {
    [Console]::CancelKeyPress += {
        param($sender, $e)
        $e.Cancel = $true
        $script:Stopping = $true
        return
    }
} catch { }

# -------------------- Startup -------------------------------------------------

# Publish current input at startup only if it was written recently.
$StartupPublishFreshSec = 180

# Tracks whether we've successfully processed at least one fresh input since start.
$script:HasSeenFreshInput      = $false
# Tracks whether startup expiry logic has been evaluated
$script:StartupExpiredChecked = $false
Init-Ui

# Clear outputs immediately on startup to prevent stale broadcasts.
Clear-OutputsFast

# Decide whether to publish the current input immediately.
$script:LastStamp = Get-InputStamp

$publishNow = $false
if (Test-Path $InFile) {
    try {
        $fi = Get-Item -LiteralPath $InFile -ErrorAction Stop
        $ageSec = ([DateTime]::UtcNow - $fi.LastWriteTimeUtc).TotalSeconds

        # Only publish immediately if the input looks "fresh".
        if ($ageSec -ge 0 -and $ageSec -le $StartupPublishFreshSec) { $publishNow = $true }
    } catch { }
}

if ($publishNow) {
    Do-Update
} else {
    if (Test-Path $InFile) {
        try { Update-Status "" "" "" "" "Expired" } catch { }
    } else {
        try { Update-Status "" "" "" "" "NotAvailable" } catch { }
    }
}

try { Update-HeartbeatBar } catch { }

try {
    while (-not $script:Stopping) {
        if (Handle-Hotkeys) { Do-Update }

        if ($script:RebuildWatcher) {
            $script:RebuildWatcher = $false
            try { Initialize-Watcher } catch { }
            # Refresh UI immediately so the 'Watching input' lines reflect the new paths.
            try { Draw-Header } catch { }
            try { Update-HeartbeatBar } catch { }
            continue
        }

        $evt = Wait-Event -Timeout $PollTimeoutSec

        if ($script:Stopping) { break }

        if ($null -eq $evt) {
            if (Handle-Hotkeys) { Do-Update }
            try { Update-HeartbeatBar } catch { }
            Do-UpdateIfNeeded
            continue
        }

        if (-not (Should-HandleEvent $evt)) {
            Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue
            try { Update-HeartbeatBar } catch { }
            continue
        }

        Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue

        Start-Sleep -Milliseconds $DebounceMs

        while ($true) {
            $evt2 = Wait-Event -Timeout 0
            if ($null -eq $evt2) { break }
            Remove-Event -EventIdentifier $evt2.EventIdentifier -ErrorAction SilentlyContinue
        }

        $stampNow = Get-InputStamp
        if ($stampNow) { $script:LastStamp = $stampNow }

        Do-Update
        try { Update-HeartbeatBar } catch { }
    }
} finally {
    try { [Console]::CursorVisible = $true } catch { }

    try { Clear-OutputsFast } catch { }

    try {
        if ($script:fsw) {
            $script:fsw.EnableRaisingEvents = $false
            $script:fsw.Dispose()
        }
    } catch { }

    try { Get-EventSubscriber | Unregister-Event -Force -ErrorAction SilentlyContinue } catch { }
    try { Get-Event | Remove-Event -ErrorAction SilentlyContinue } catch { }

    try {
        if ($script:MutexHasHandle -and $script:Mutex) { $script:Mutex.ReleaseMutex() | Out-Null }
    } catch { }
    try {
        if ($script:Mutex) { $script:Mutex.Dispose() }
    } catch { }
# True only if the input file existed at startup and was already older than the startup freshness window.
$script:StartupInputWasExpired = $false
}
