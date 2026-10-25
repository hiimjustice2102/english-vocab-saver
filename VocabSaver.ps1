# Vocab Saver - boi den + Ctrl+C de luu tu tieng Anh, 5 phut lam 1 bai trac nghiem.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Windows.Forms.Application]::EnableVisualStyles()

$Dir      = Join-Path $env:APPDATA 'VocabSaver'
$DataFile = Join-Path $Dir 'words.json'
$CfgFile  = Join-Path $Dir 'settings.json'

# Khoang thoi gian giua 2 bai tap (phut), luu lai giua cac lan mo app
$QuizMinutes = 5
if (Test-Path $CfgFile) {
    try { $m = [int](Get-Content $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json).quizMinutes; if ($m -ge 1 -and $m -le 240) { $QuizMinutes = $m } } catch { }
}
function Save-Settings {
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory $Dir | Out-Null }
    [IO.File]::WriteAllText($CfgFile, (@{ quizMinutes = $script:QuizMinutes } | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}
$WordRe   = "^[A-Za-z][A-Za-z'’-]*( [A-Za-z][A-Za-z'’-]*){0,3}$"   # 1-4 tu tieng Anh

# Moi loi deu ghi ra file log + hien hop thoai (vi app chay an)
$LogFile = Join-Path $env:TEMP 'VocabSaver_error.log'
trap {
    $msg = "$($_.Exception.Message)`r`nDong $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    Add-Content $LogFile "[$(Get-Date -Format s)] $msg"
    [Windows.Forms.MessageBox]::Show($msg, 'Vocab Saver - Lỗi') | Out-Null
    continue
}

$created = $false
$mutex = New-Object Threading.Mutex($true, 'VocabSaver_SingleInstance', [ref]$created)
if (-not $created) {
    [Windows.Forms.MessageBox]::Show('Vocab Saver đã đang chạy. Tìm icon (i) ở khay hệ thống, có thể nằm trong mũi tên ^ ở góc phải taskbar.', 'Vocab Saver') | Out-Null
    exit
}

# Win32: bo goc cua so, keo cua so khong vien, trang thai trinh chieu. Loi thi bo qua.
$script:HasNative = $false
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VsNative {
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("shell32.dll")] public static extern int SHQueryUserNotificationState(out int state);
}
'@
    $script:HasNative = $true
} catch { }

# ---------- Du lieu ----------
$script:Words = New-Object System.Collections.ArrayList
if (Test-Path $DataFile) {
    foreach ($w in (Get-Content $DataFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        if (-not ($w.PSObject.Properties.Name -contains 'phonetic'))   { $w | Add-Member phonetic '' }     # du lieu ban cu
        if (-not ($w.PSObject.Properties.Name -contains 'definition')) { $w | Add-Member definition '' }
        [void]$script:Words.Add($w)
    }
}

function Save-Words {
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory $Dir | Out-Null }
    $json = ConvertTo-Json -InputObject @($script:Words.ToArray()) -Depth 3
    [IO.File]::WriteAllText($DataFile, $json, (New-Object Text.UTF8Encoding $false))
}

function New-Client {
    $wc = New-Object Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    if ($wc.Proxy) { $wc.Proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials }  # proxy cong ty
    $wc
}

# Ma loi HTTP (vd 429) tu exception cua WebClient, khong co thi 0
function Get-HttpStatus($err) {
    $ex = $err.Exception
    while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
    if ($ex -and $ex.Response) { return [int]$ex.Response.StatusCode }
    0
}

$script:GoogleBlockedUntil = [DateTime]::MinValue

function Get-GoogleTranslation($text) {
    $url = 'https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=vi&dt=t&q=' + [Uri]::EscapeDataString($text)
    $data = (New-Client).DownloadString($url) | ConvertFrom-Json
    ($data[0] | ForEach-Object { $_[0] }) -join ''
}

# Du phong: MyMemory (mien phi, khong can key, ~5.000 ky tu/ngay tinh theo IP)
function Get-MyMemoryTranslation($text) {
    $url = 'https://api.mymemory.translated.net/get?langpair=en|vi&q=' + [Uri]::EscapeDataString($text)
    $r = (New-Client).DownloadString($url) | ConvertFrom-Json
    $t = $r.responseData.translatedText
    if ([int]$r.responseStatus -ne 200 -or -not $t -or $t -match 'MYMEMORY WARNING') {
        throw "MyMemory: $($r.responseDetails) (status $($r.responseStatus))"
    }
    [Net.WebUtility]::HtmlDecode($t)
}

# Thu Google truoc. Bi 429 thi nghi Google 15 phut va dung MyMemory. Ca 2 loi thi throw.
function Get-Translation($text) {
    $errs = @()
    if ([DateTime]::Now -ge $script:GoogleBlockedUntil) {
        try { return Get-GoogleTranslation $text }
        catch {
            if ((Get-HttpStatus $_) -eq 429) { $script:GoogleBlockedUntil = [DateTime]::Now.AddMinutes(15) }
            $errs += "Google: HTTP $(Get-HttpStatus $_)"
        }
    } else { $errs += 'Google: đang tạm nghỉ do bị giới hạn (429)' }
    try { return Get-MyMemoryTranslation $text }
    catch { $errs += "$($_.Exception.Message)" }
    throw ($errs -join ' | ')
}

# Tra tu dien. Tra ve mang ket qua, @() neu khong co tu (404), $null neu loi mang.
$script:DictCache = @{}
function Get-DictEntry($w) {
    if ($script:DictCache.ContainsKey($w)) { return ,$script:DictCache[$w] }
    try {
        $j = @((New-Client).DownloadString('https://api.dictionaryapi.dev/api/v2/entries/en/' + [Uri]::EscapeDataString($w)) | ConvertFrom-Json)
    } catch {
        $ex = $_.Exception
        while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
        if ($ex -and $ex.Response -and [int]$ex.Response.StatusCode -eq 404) { $j = @() } else { return $null }
    }
    $script:DictCache[$w] = $j
    ,$j
}

# $true = co nghia dong tu, $false = khong (hoac khong co trong tu dien), $null = loi mang
function Test-Verb($w) {
    $j = Get-DictEntry $w
    if ($null -eq $j) { return $null }
    [bool](@($j | ForEach-Object { $_.meanings } | Where-Object { $_.partOfSpeech -eq 'verb' }).Count)
}

# Phien am IPA, vd /ˈrʌn/. Cum nhieu tu: ghep phien am tung tu. Khong co thi tra ve ''.
function Get-Phonetic($text) {
    $parts = @()
    foreach ($t in ($text -split ' ')) {
        $j = Get-DictEntry $t
        if (-not $j) { return '' }
        $p = @($j | ForEach-Object { $_.phonetic; $_.phonetics | ForEach-Object { $_.text } } | Where-Object { $_ }) | Select-Object -First 1
        if (-not $p) { return '' }
        $parts += $p.Trim('/', '[', ']', ' ')
    }
    '/' + ($parts -join ' ') + '/'
}

# Dinh nghia tieng Anh dau tien, vd "(verb) To move swiftly on foot." Khong co thi ''.
# $preferVerb: uu tien nghia dong tu (khi tu duoc doi tu dang -ing/-ed/bat quy tac ve nguyen mau)
function Get-Definition($text, [bool]$preferVerb = $false) {
    $j = Get-DictEntry $text
    if (-not $j) { return '' }
    $ms = @($j | ForEach-Object { $_.meanings } | Where-Object { $_.definitions })
    if (-not $ms) { return '' }
    $m = $null
    if ($preferVerb) { $m = $ms | Where-Object { $_.partOfSpeech -eq 'verb' } | Select-Object -First 1 }
    if (-not $m) { $m = $ms[0] }
    $d = $m.definitions[0].definition
    if (-not $d) { return '' }
    "($($m.partOfSpeech)) $d"
}

# Dong tu bat quy tac: dang qua khu / phan tu -> nguyen mau (tra offline, khong can mang)
# Co tinh bo qua cac dang de nham voi tu khac: lay, bound, wound, ground, rose, bit, bore.
$IrregularList = @'
be=was,were,been
arise=arose,arisen
awake=awoke,awoken
beat=beaten
become=became
begin=began,begun
bend=bent
bite=bitten
bleed=bled
blow=blew,blown
break=broke,broken
breed=bred
bring=brought
build=built
burn=burnt
buy=bought
catch=caught
choose=chose,chosen
cling=clung
come=came
creep=crept
deal=dealt
dig=dug
do=did,done
draw=drew,drawn
dream=dreamt
drink=drank,drunk
drive=drove,driven
eat=ate,eaten
fall=fell,fallen
feed=fed
feel=felt
fight=fought
find=found
flee=fled
fly=flew,flown
forbid=forbade,forbidden
foresee=foresaw,foreseen
forget=forgot,forgotten
forgive=forgave,forgiven
freeze=froze,frozen
get=got,gotten
give=gave,given
go=went,gone
grow=grew,grown
hang=hung
have=had
hear=heard
hide=hid,hidden
hold=held
keep=kept
kneel=knelt
know=knew,known
lead=led
lean=leant
leap=leapt
learn=learnt
leave=left
lend=lent
lie=lain
light=lit
lose=lost
make=made
mean=meant
meet=met
mislead=misled
mistake=mistook,mistaken
overcome=overcame
oversee=oversaw,overseen
overtake=overtook,overtaken
pay=paid
prove=proven
rebuild=rebuilt
rewrite=rewrote,rewritten
ride=rode,ridden
ring=rang,rung
rise=risen
run=ran
say=said
see=saw,seen
seek=sought
sell=sold
send=sent
sew=sewn
shake=shook,shaken
shine=shone
shoot=shot
show=shown
shrink=shrank,shrunk
sing=sang,sung
sink=sank,sunk
sit=sat
sleep=slept
slide=slid
speak=spoke,spoken
speed=sped
spend=spent
spin=spun
spring=sprang,sprung
stand=stood
steal=stole,stolen
stick=stuck
sting=stung
strike=struck,stricken
strive=strove,striven
swear=swore,sworn
sweep=swept
swim=swam,swum
swing=swung
take=took,taken
teach=taught
tear=tore,torn
tell=told
think=thought
throw=threw,thrown
undergo=underwent,undergone
understand=understood
undertake=undertook,undertaken
uphold=upheld
wake=woke,woken
wear=wore,worn
weave=wove,woven
weep=wept
win=won
withdraw=withdrew,withdrawn
withhold=withheld
write=wrote,written
'@
$script:Irregular = @{}
foreach ($line in ($IrregularList -split "`n")) {
    $base, $forms = $line.Trim() -split '='
    if (-not $forms) { continue }
    foreach ($f in ($forms -split ',')) { if ($f -ne $base) { $script:Irregular[$f] = $base } }
}

# running -> run, hoped -> hope, studied -> study, went -> go. Khong chac chan thi giu nguyen.
function Get-BaseForm($w) {
    if ($script:Irregular.ContainsKey($w)) { return $script:Irregular[$w] }
    if ($w -notmatch '^[a-z]{4,}$' -or $w -notmatch '(ing|ed)$') { return $w }
    if ((Test-Verb $w) -ne $false) { return $w }      # ban than la dong tu (need, bring...) hoac loi mang
    $s = if ($w.EndsWith('ing')) { $w.Substring(0, $w.Length - 3) } else { $w.Substring(0, $w.Length - 2) }
    $c = @()
    if ($w.EndsWith('ied')) { $c += $w.Substring(0, $w.Length - 3) + 'y' }
    if ($s -match '[^aeiou][aeiou][^aeiouwxy]$') { $c += "${s}e", $s } else { $c += $s, "${s}e" }   # hop -> hope truoc
    if ($s -match '([^aeiou])\1$') { $c += $s.Substring(0, $s.Length - 1) }                          # runn -> run
    foreach ($x in ($c | Select-Object -Unique)) {
        if ($x.Length -lt 2) { continue }
        $r = Test-Verb $x
        if ($null -eq $r) { return $w }
        if ($r) { return $x }
    }
    $w
}

function Show-Tip($title, $text) {
    if (-not $text) { $text = ' ' }
    $script:Tray.ShowBalloonTip(3000, $title, $text, [Windows.Forms.ToolTipIcon]::Info)
}

# ---------- Doc phat am (giong doc co san cua Windows, khong can mang) ----------
$script:Synth = $null
try {
    Add-Type -AssemblyName System.Speech
    $script:Synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $voices = @($script:Synth.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name -like 'en-*' })
    $pick = (@($voices | Where-Object { $_.VoiceInfo.Culture.Name -eq 'en-US' }) + $voices) | Select-Object -First 1
    if ($pick) { $script:Synth.SelectVoice($pick.VoiceInfo.Name); $script:Synth.Rate = -1 }   # cham hon 1 chut
    else { $script:Synth.Dispose(); $script:Synth = $null }
} catch { $script:Synth = $null }

function Invoke-Speak($text) {
    if (-not $text) { return }
    if (-not $script:Synth) {
        Show-Tip 'Không có giọng đọc tiếng Anh' 'Cài thêm: Settings > Time & language > Speech > Add voices > English (United States).'
        return
    }
    $script:Synth.SpeakAsyncCancelAll()
    [void]$script:Synth.SpeakAsync($text)
}

function Add-Word($text) {
    $orig = $text.ToLower()
    $key = Get-BaseForm $orig
    $from = if ($key -ne $orig) { " (từ $orig)" } else { '' }
    $old = $script:Words | Where-Object { $_.word -eq $key } | Select-Object -First 1
    if ($old) { Show-Tip "Đã có: $key $($old.phonetic)" $old.meaning; return }
    $meaning = ''
    try { $meaning = Get-Translation $key }
    catch { Add-Content $LogFile "[$(Get-Date -Format s)] Dịch '$key' lỗi: $($_.Exception.Message)" }
    $ph = Get-Phonetic $key
    $def = Get-Definition $key ($key -ne $orig)
    [void]$script:Words.Add([pscustomobject]@{ word = $key; phonetic = $ph; meaning = $meaning; definition = $def; added = (Get-Date).ToString('s'); correct = 0; wrong = 0 })
    Save-Words
    if (-not $meaning) {
        Show-Tip "✓ Đã lưu: $key$from" 'Dịch vụ dịch đang quá tải. App sẽ tự dịch lại sau vài phút.'
        return
    }
    $body = if ($def) { "$meaning`n$def" } else { $meaning }
    Show-Tip "✓ Đã lưu: $key $ph$from" $body
}

# Bo sung phien am + dinh nghia cho tu luu tu ban cu (chi thu 1 lan moi phien chay)
$script:PhTried = @{}
function Update-Phonetic($w) {
    if (($w.phonetic -and $w.definition) -or $script:PhTried.ContainsKey($w.word)) { return }
    $script:PhTried[$w.word] = $true
    $changed = $false
    if (-not $w.phonetic)   { $ph = Get-Phonetic $w.word;   if ($ph) { $w.phonetic = $ph;   $changed = $true } }
    if (-not $w.definition) { $df = Get-Definition $w.word; if ($df) { $w.definition = $df; $changed = $true } }
    if ($changed) { Save-Words }
}

# ---------- Giao dien ----------
function Hex($h) { [Drawing.ColorTranslator]::FromHtml($h) }

# Doc che do sang/toi cua Windows moi lan mo cua so
function Get-Theme {
    $dark = $false
    try { $dark = (Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' AppsUseLightTheme) -eq 0 } catch { }
    if ($dark) {
        @{ IsDark = $true
           Accent = (Hex '#A5B4FC'); Text = (Hex '#F3F4F6'); Muted = (Hex '#9CA3AF'); Danger = (Hex '#F87171')
           Line   = (Hex '#3F3F46'); Bg   = (Hex '#1F1F23'); Input = (Hex '#2A2A30'); Header = (Hex '#27272A')
           normal = @{ Back = (Hex '#2A2A30'); Border = (Hex '#3F3F46'); Hover = (Hex '#312E81'); Fore = (Hex '#F3F4F6') }
           right  = @{ Back = (Hex '#14532D'); Border = (Hex '#22C55E'); Hover = (Hex '#14532D'); Fore = (Hex '#BBF7D0') }
           wrong  = @{ Back = (Hex '#7F1D1D'); Border = (Hex '#EF4444'); Hover = (Hex '#7F1D1D'); Fore = (Hex '#FECACA') } }
    } else {
        @{ IsDark = $false
           Accent = (Hex '#4F46E5'); Text = (Hex '#111827'); Muted = (Hex '#6B7280'); Danger = (Hex '#DC2626')
           Line   = (Hex '#E5E7EB'); Bg   = (Hex '#FFFFFF'); Input = (Hex '#FFFFFF'); Header = (Hex '#F3F4F6')
           normal = @{ Back = (Hex '#F9FAFB'); Border = (Hex '#E5E7EB'); Hover = (Hex '#EEF2FF'); Fore = (Hex '#111827') }
           right  = @{ Back = (Hex '#DCFCE7'); Border = (Hex '#16A34A'); Hover = (Hex '#DCFCE7'); Fore = (Hex '#166534') }
           wrong  = @{ Back = (Hex '#FEE2E2'); Border = (Hex '#DC2626'); Hover = (Hex '#FEE2E2'); Fore = (Hex '#991B1B') } }
    }
}
$script:Theme = Get-Theme

# Thanh tieu de toi (Windows 10 20H1+ / 11)
function Set-TitleBar($form) {
    if ($script:HasNative -and $script:Theme.IsDark) { $v = 1; [void][VsNative]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4) }
}

function New-ThemedButton($text, $primary) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.FlatStyle = 'Flat'; $b.Cursor = 'Hand'; $b.UseMnemonic = $false
    if ($primary) {
        $b.BackColor = $Theme.Accent; $b.ForeColor = if ($Theme.IsDark) { $Theme.Bg } else { [Drawing.Color]::White }
        $b.FlatAppearance.BorderColor = $Theme.Accent
    } else {
        $b.BackColor = $Theme.normal.Back; $b.ForeColor = $Theme.Text
        $b.FlatAppearance.BorderColor = $Theme.Line; $b.FlatAppearance.MouseOverBackColor = $Theme.normal.Hover
    }
    $b
}

# Nut loa: icon trong font Segoe MDL2 Assets (co san tu Windows 10)
function New-SpeakButton($x, $y, $size) {
    $b = New-Object Windows.Forms.Button
    $b.Text = [string][char]0xE767
    $b.Font = New-Object Drawing.Font('Segoe MDL2 Assets', 13)
    $b.FlatStyle = 'Flat'; $b.Cursor = 'Hand'; $b.TabStop = $false
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = $Theme.normal.Hover
    $b.BackColor = $Theme.Bg; $b.ForeColor = $Theme.Accent
    $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($size, $size)
    $b
}

function Set-OptStyle($b, $kind) {
    $c = $Theme[$kind]
    $b.BackColor = $c.Back
    $b.ForeColor = $c.Fore
    $b.FlatAppearance.BorderColor = $c.Border
    $b.FlatAppearance.MouseOverBackColor = $c.Hover
    $b.FlatAppearance.MouseDownBackColor = $c.Hover
}

function New-FlatButton($text, $x, $y, $w, $h) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.UseMnemonic = $false; $b.TabStop = $false
    $b.FlatStyle = 'Flat'; $b.Cursor = 'Hand'
    $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, $h)
    $b
}

# Keo cua so bang cach giu chuot vao vung trong
$onDrag = {
    param($s, $e)
    if ($script:HasNative -and $e.Button -eq 'Left') {
        [void][VsNative]::ReleaseCapture()
        [void][VsNative]::SendMessage($s.FindForm().Handle, 0xA1, [IntPtr]2, [IntPtr]::Zero)
    }
}

# ---------- Bai tap ----------
$script:QuizOpen = $false

$onAnswer = {
    param($s, $e)
    $form = $s.FindForm()
    $q = $form.Tag
    if ($q.done) { return }
    $q.done = $true
    $ok = $s.Tag -eq $q.answer
    foreach ($b in $q.buttons) {
        if ($b.Tag -eq $q.answer) { Set-OptStyle $b 'right' }
        elseif ($b -eq $s)        { Set-OptStyle $b 'wrong' }
        else { $b.ForeColor = $Theme.Muted; $b.FlatAppearance.MouseOverBackColor = $b.BackColor }
        $b.Cursor = 'Default'
    }
    if ($ok) {
        $q.item.correct++
        $q.feedback.Text = '✓ Chính xác!'; $q.feedback.ForeColor = $Theme.right.Fore
    } else {
        $q.item.wrong++
        $q.feedback.Text = '✗ Chưa đúng, đáp án đúng tô xanh'; $q.feedback.ForeColor = $Theme.wrong.Fore
    }
    Save-Words
    # Hien dinh nghia tieng Anh sau khi tra loi (khong hien truoc de khoi lo dap an)
    $hasDef = [bool]$q.item.definition
    if ($hasDef) {
        $q.def.Text = $q.item.definition
        $q.def.Visible = $true
        $form.Height += $q.def.PreferredHeight + 12
    }
    $t = New-Object Windows.Forms.Timer
    $t.Interval = if ($hasDef) { if ($ok) { 4000 } else { 6000 } } elseif ($ok) { 1200 } else { 2500 }
    $t.Tag = $form
    $t.Add_Tick({ param($t2, $e2) $t2.Stop(); if (-not $t2.Tag.IsDisposed) { $t2.Tag.Close() } })
    $t.Start()
}

function Show-Quiz([switch]$Manual) {
    if ($script:QuizOpen) { return }
    $ready = @($script:Words | Where-Object { $_.meaning })      # bo qua tu dang cho dich
    if ($ready.Count -lt 4) {
        if ($Manual) { Show-Tip 'Chưa đủ từ' 'Cần ít nhất 4 từ đã có nghĩa để làm bài.' }
        return
    }
    # Uu tien tu hay sai: lay 1/3 tu diem thap nhat roi chon ngau nhien
    $sorted = @($ready | Sort-Object { $_.correct - $_.wrong })
    $n = [Math]::Max(3, [Math]::Ceiling($sorted.Count / 3))
    $item = $sorted[0..($n - 1)] | Get-Random
    $answer = $item.meaning
    $distractors = @($ready | ForEach-Object { $_.meaning } | Where-Object { $_ -ne $answer } |
                     Select-Object -Unique | Get-Random -Count 3)
    if ($distractors.Count -lt 3) { return }
    $options = (@($answer) + $distractors) | Get-Random -Count 4

    $script:QuizOpen = $true
    $script:Theme = Get-Theme
    Update-Phonetic $item

    # Khung: form khong vien, nen 1px lam duong vien, panel ben trong
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Vocab Saver - Bài tập'
    $f.FormBorderStyle = 'None'
    $f.TopMost = $true
    $f.StartPosition = 'CenterScreen'
    $f.BackColor = $Theme.Line
    $f.Padding = New-Object Windows.Forms.Padding(1)
    $f.Font = New-Object Drawing.Font('Segoe UI', 10)

    $p = New-Object Windows.Forms.Panel
    $p.Dock = 'Fill'; $p.BackColor = $Theme.Bg
    $p.Add_MouseDown($onDrag)
    $f.Controls.Add($p)

    $badge = New-Object Windows.Forms.Label
    $badge.Text = 'VOCAB QUIZ'; $badge.AutoSize = $true; $badge.Location = '28,22'
    $badge.ForeColor = $Theme.Accent
    $badge.Font = New-Object Drawing.Font('Segoe UI', 8.5, [Drawing.FontStyle]::Bold)

    $close = New-FlatButton '✕' 414 10 34 30
    $close.FlatAppearance.BorderSize = 0
    $close.FlatAppearance.MouseOverBackColor = $Theme.Line
    $close.ForeColor = $Theme.Muted; $close.BackColor = $Theme.Bg
    $close.Add_Click({ param($s, $e) $s.FindForm().Close() })

    $prompt = New-Object Windows.Forms.Label
    $prompt.Text = 'Nghĩa của từ này là gì?'; $prompt.AutoSize = $true; $prompt.Location = '28,50'
    $prompt.ForeColor = $Theme.Muted

    $wordLbl = New-Object Windows.Forms.Label
    $wordLbl.Text = $item.word; $wordLbl.AutoEllipsis = $true; $wordLbl.UseMnemonic = $false
    $wordLbl.Location = '24,72'; $wordLbl.Size = '360,52'
    $wordLbl.ForeColor = $Theme.Text
    $wordLbl.Font = New-Object Drawing.Font('Segoe UI Semibold', 24)

    $spk = New-SpeakButton 390 78 40
    $spk.Tag = $item.word
    $spk.Add_Click({ param($s, $e) Invoke-Speak $s.Tag })

    $phLbl = New-Object Windows.Forms.Label
    $phLbl.Text = $item.phonetic; $phLbl.AutoEllipsis = $true; $phLbl.UseMnemonic = $false
    $phLbl.Location = '28,124'; $phLbl.Size = '402,24'
    $phLbl.ForeColor = $Theme.Accent
    $phLbl.Font = New-Object Drawing.Font('Segoe UI', 12)

    foreach ($c in @($badge, $prompt, $wordLbl, $phLbl)) { $c.Add_MouseDown($onDrag) }
    $p.Controls.AddRange(@($badge, $close, $prompt, $wordLbl, $spk, $phLbl))

    $btns = @()
    $letters = 'A', 'B', 'C', 'D'
    $y = if ($item.phonetic) { 160 } else { 136 }
    for ($i = 0; $i -lt 4; $i++) {
        $b = New-FlatButton "$($letters[$i]).   $($options[$i])" 28 $y 402 48
        $b.Tag = $options[$i]
        $b.TextAlign = 'MiddleLeft'; $b.AutoEllipsis = $true
        $b.Padding = New-Object Windows.Forms.Padding(12, 0, 12, 0)
        $b.Font = New-Object Drawing.Font('Segoe UI', 11)
        Set-OptStyle $b 'normal'
        $b.Add_Click($onAnswer)
        $p.Controls.Add($b)
        $btns += $b
        $y += 58
    }

    $fb = New-Object Windows.Forms.Label
    $fb.AutoSize = $true; $fb.Location = New-Object Drawing.Point(28, ($y + 8))
    $fb.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)

    $skip = New-FlatButton 'Bỏ qua' 350 ($y + 2) 80 32
    $skip.FlatAppearance.BorderSize = 0
    $skip.FlatAppearance.MouseOverBackColor = $Theme.Line
    $skip.ForeColor = $Theme.Muted; $skip.BackColor = $Theme.Bg
    $skip.Add_Click({ param($s, $e) $s.FindForm().Close() })

    $def = New-Object Windows.Forms.Label
    $def.AutoSize = $true; $def.MaximumSize = New-Object Drawing.Size(402, 0); $def.UseMnemonic = $false
    $def.Location = New-Object Drawing.Point(28, ($y + 44))
    $def.ForeColor = $Theme.Muted; $def.Visible = $false
    $def.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Italic)
    $def.Add_MouseDown($onDrag)
    $p.Controls.AddRange(@($fb, $skip, $def))

    $f.ClientSize = New-Object Drawing.Size(460, ($y + 52))
    $f.CancelButton = $skip      # Esc = bo qua
    $f.Tag = @{ answer = $answer; item = $item; done = $false; buttons = $btns; feedback = $fb; def = $def }
    $f.Add_Shown({
        param($s, $e)
        if ($script:HasNative) { $v = 2; [void][VsNative]::DwmSetWindowAttribute($s.Handle, 33, [ref]$v, 4) }  # bo goc Win11
        $s.Activate()
    })

    [void]$f.ShowDialog()
    $f.Dispose()
    $script:QuizOpen = $false
}

# ---------- Danh sach tu ----------
# Hop thoai sua tu / phien am / nghia / dinh nghia. Tra ve hashtable hoac $null neu huy.
function Show-EditDialog($w, $owner) {
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Sửa từ'; $f.FormBorderStyle = 'FixedDialog'; $f.StartPosition = 'CenterParent'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false
    $f.ClientSize = '380,350'; $f.Font = New-Object Drawing.Font('Segoe UI', 10)
    $f.BackColor = $Theme.Bg; $f.ForeColor = $Theme.Text

    $l1 = New-Object Windows.Forms.Label; $l1.Text = 'Từ'; $l1.Location = '16,12'; $l1.AutoSize = $true; $l1.ForeColor = $Theme.Muted
    $tbW = New-Object Windows.Forms.TextBox; $tbW.Text = $w.word; $tbW.Location = '16,34'; $tbW.Width = 308
    $spk = New-SpeakButton 330 30 34
    $spk.Tag = $tbW
    $spk.Add_Click({ param($s, $e) Invoke-Speak $s.Tag.Text.Trim() })
    $l3 = New-Object Windows.Forms.Label; $l3.Text = 'Phát âm'; $l3.Location = '16,70'; $l3.AutoSize = $true; $l3.ForeColor = $Theme.Muted
    $tbP = New-Object Windows.Forms.TextBox; $tbP.Text = $w.phonetic; $tbP.Location = '16,92'; $tbP.Width = 348
    $l2 = New-Object Windows.Forms.Label; $l2.Text = 'Nghĩa'; $l2.Location = '16,128'; $l2.AutoSize = $true; $l2.ForeColor = $Theme.Muted
    $tbM = New-Object Windows.Forms.TextBox; $tbM.Text = $w.meaning; $tbM.Location = '16,150'; $tbM.Width = 348
    $l4 = New-Object Windows.Forms.Label; $l4.Text = 'Định nghĩa (tiếng Anh)'; $l4.Location = '16,186'; $l4.AutoSize = $true; $l4.ForeColor = $Theme.Muted
    $tbD = New-Object Windows.Forms.TextBox; $tbD.Text = $w.definition; $tbD.Location = '16,208'; $tbD.Size = '348,78'
    $tbD.Multiline = $true; $tbD.ScrollBars = 'Vertical'
    foreach ($tb in @($tbW, $tbP, $tbM, $tbD)) { $tb.BorderStyle = 'FixedSingle'; $tb.BackColor = $Theme.Input; $tb.ForeColor = $Theme.Text }

    $tr = New-ThemedButton 'Tra lại' $false; $tr.Location = '16,300'; $tr.Size = '100,34'
    $ok = New-ThemedButton 'Lưu' $true;      $ok.Location = '186,300'; $ok.Size = '86,34'
    $no = New-ThemedButton 'Hủy' $false;     $no.Location = '278,300'; $no.Size = '86,34'
    $no.DialogResult = 'Cancel'
    $f.Controls.AddRange(@($l1, $tbW, $spk, $l3, $tbP, $l2, $tbM, $l4, $tbD, $tr, $ok, $no))
    $f.AcceptButton = $ok; $f.CancelButton = $no
    $f.Tag = @{ word = $tbW; ph = $tbP; mean = $tbM; def = $tbD; orig = $w.word }

    # Tra lai nghia + phien am + dinh nghia cho tu dang nhap
    $tr.Add_Click({
        param($s, $e)
        $d = $s.FindForm().Tag
        $txt = ($d.word.Text.Trim() -replace '\s+', ' ').ToLower()
        if (-not $txt) { return }
        $s.FindForm().Cursor = 'WaitCursor'
        try { $d.mean.Text = Get-Translation $txt }
        catch { [Windows.Forms.MessageBox]::Show("Không dịch được: $($_.Exception.Message)", 'Sửa từ') | Out-Null }
        $d.ph.Text = Get-Phonetic $txt
        $d.def.Text = Get-Definition $txt
        $s.FindForm().Cursor = 'Default'
    })
    $ok.Add_Click({
        param($s, $e)
        $form = $s.FindForm(); $d = $form.Tag
        $nw = ($d.word.Text.Trim() -replace '\s+', ' ').ToLower()
        $nm = $d.mean.Text.Trim()
        if (-not $nw -or -not $nm) { [Windows.Forms.MessageBox]::Show('Từ và nghĩa không được để trống.', 'Sửa từ') | Out-Null; return }
        if ($nw -ne $d.orig -and ($script:Words | Where-Object { $_.word -eq $nw })) {
            [Windows.Forms.MessageBox]::Show("Từ '$nw' đã có trong danh sách.", 'Sửa từ') | Out-Null; return
        }
        $form.DialogResult = 'OK'
    })
    $f.Add_Shown({ param($s, $e) Set-TitleBar $s })

    $res = $null
    if ($f.ShowDialog($owner) -eq 'OK') {
        $res = @{ word = ($tbW.Text.Trim() -replace '\s+', ' ').ToLower(); phonetic = $tbP.Text.Trim()
                  meaning = $tbM.Text.Trim(); definition = ($tbD.Text.Trim() -replace '\s+', ' ') }
    }
    $f.Dispose()
    $res
}

# Cot: 0 Nghe, 1 Tu, 2 Phat am, 3 Nghia, 4 Dinh nghia EN, 5 Dung/Sai, 6 Thung rac. Item.Tag = tu (khoa).
$ColSpeak = 0; $ColTrash = 6

function Edit-Word($list) {
    if ($list.SelectedItems.Count -ne 1) { return }
    $it = $list.SelectedItems[0]
    $w = $script:Words | Where-Object { $_.word -eq $it.Tag } | Select-Object -First 1
    if (-not $w) { return }
    $r = Show-EditDialog $w $list.FindForm()
    if (-not $r) { return }
    $w.word = $r.word; $w.phonetic = $r.phonetic; $w.meaning = $r.meaning; $w.definition = $r.definition   # giu so lan dung/sai
    $it.Tag = $r.word
    $it.ToolTipText = $r.definition
    $it.SubItems[1].Text = $r.word
    $it.SubItems[2].Text = $r.phonetic
    $it.SubItems[3].Text = $r.meaning
    $it.SubItems[4].Text = $r.definition
    Save-Words
}

function Remove-WordRow($list, $it) {
    $ans = [Windows.Forms.MessageBox]::Show($list.FindForm(), "Xóa từ '$($it.Tag)' khỏi danh sách?`r`n`r`nSố lần đúng/sai của từ này cũng sẽ bị xóa.",
        'Xác nhận xóa', 'YesNo', 'Warning', 'Button2')      # mac dinh chon No
    if ($ans -ne 'Yes') { return }
    for ($i = $script:Words.Count - 1; $i -ge 0; $i--) {
        if ($script:Words[$i].word -eq $it.Tag) { $script:Words.RemoveAt($i) }
    }
    $list.Items.Remove($it)
    Save-Words
    $list.FindForm().Text = "Từ đã lưu ($($script:Words.Count))  ·  double-click vào từ để sửa"
}

# Tra ve @{ item; col } cua o dang nam duoi chuot, hoac $null
function Get-HitCell($list, $pt) {
    $hit = $list.HitTest($pt)
    if (-not $hit.Item -or -not $hit.SubItem) { return $null }
    @{ item = $hit.Item; col = $hit.Item.SubItems.IndexOf($hit.SubItem) }
}

function Show-List {
    $script:Theme = Get-Theme
    $f = New-Object Windows.Forms.Form
    $f.Text = "Từ đã lưu ($($script:Words.Count))  ·  double-click vào từ để sửa"
    $f.Size = '1080,480'; $f.StartPosition = 'CenterScreen'
    $f.Font = New-Object Drawing.Font('Segoe UI', 10)
    $f.BackColor = $Theme.Bg; $f.ForeColor = $Theme.Text

    $lv = New-Object Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.Dock = 'Fill'
    $lv.BorderStyle = 'None'; $lv.BackColor = $Theme.Bg; $lv.ForeColor = $Theme.Text
    $lv.ShowItemToolTips = $true
    [void]$lv.Columns.Add('Nghe', 56)
    [void]$lv.Columns.Add('Từ', 140)
    [void]$lv.Columns.Add('Phát âm', 140)
    [void]$lv.Columns.Add('Nghĩa', 220)
    [void]$lv.Columns.Add('Định nghĩa (EN)', 340)
    [void]$lv.Columns.Add('Đúng / Sai', 90)
    [void]$lv.Columns.Add('', 44)
    # Tu ve header de theo mau theme (header mac dinh cua Windows luon sang)
    $lv.OwnerDraw = $true
    $lv.Add_DrawColumnHeader({
        param($s, $e)
        $br = New-Object Drawing.SolidBrush($script:Theme.Header)
        $e.Graphics.FillRectangle($br, $e.Bounds); $br.Dispose()
        $r = New-Object Drawing.Rectangle(($e.Bounds.X + 6), $e.Bounds.Y, ($e.Bounds.Width - 6), $e.Bounds.Height)
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $s.Font, $r, $script:Theme.Muted,
            [Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis')
    })
    $lv.Add_DrawItem({ param($s, $e) $e.DrawDefault = $true })
    $lv.Add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })

    # Bam cot Nghe = doc tu, bam icon thung rac = xoa tu
    $lv.Add_MouseClick({
        param($s, $e)
        $c = Get-HitCell $s $e.Location
        if (-not $c) { return }
        if ($c.col -eq $ColSpeak) { Invoke-Speak $c.item.Tag }
        elseif ($c.col -eq $ColTrash) { Remove-WordRow $s $c.item }
    })
    # Double-click vao cac cot noi dung = sua tu
    $lv.Add_MouseDoubleClick({
        param($s, $e)
        $c = Get-HitCell $s $e.Location
        if ($c -and $c.col -ne $ColSpeak -and $c.col -ne $ColTrash) { Edit-Word $s }
    })
    # Con tro hinh ban tay khi re vao nut Nghe / thung rac
    $lv.Add_MouseMove({
        param($s, $e)
        $c = Get-HitCell $s $e.Location
        $s.Cursor = if ($c -and ($c.col -eq $ColSpeak -or $c.col -eq $ColTrash)) { 'Hand' } else { 'Default' }
    })

    $iconFont = New-Object Drawing.Font('Segoe MDL2 Assets', 11)
    $trashGlyph = [string][char]0xE74D      # icon Delete (thung rac)
    foreach ($w in ($script:Words | Sort-Object added -Descending)) {
        $it = New-Object Windows.Forms.ListViewItem('  ▶')
        $it.Tag = $w.word
        $it.ToolTipText = $w.definition
        $it.ForeColor = $Theme.Accent; $it.UseItemStyleForSubItems = $false
        [void]$it.SubItems.Add($w.word, $Theme.Text, $Theme.Bg, $lv.Font)
        [void]$it.SubItems.Add($w.phonetic, $Theme.Text, $Theme.Bg, $lv.Font)
        if ($w.meaning) { [void]$it.SubItems.Add($w.meaning, $Theme.Text, $Theme.Bg, $lv.Font) }
        else            { [void]$it.SubItems.Add('(đang chờ dịch...)', $Theme.Muted, $Theme.Bg, $lv.Font) }
        [void]$it.SubItems.Add($w.definition, $Theme.Muted, $Theme.Bg, $lv.Font)
        [void]$it.SubItems.Add("✓$($w.correct)  ✗$($w.wrong)", $Theme.Text, $Theme.Bg, $lv.Font)
        [void]$it.SubItems.Add("  $trashGlyph", $Theme.Danger, $Theme.Bg, $iconFont)
        [void]$lv.Items.Add($it)
    }

    $f.Controls.Add($lv)
    $f.Add_Shown({ param($s, $e) Set-TitleBar $s })
    [void]$f.ShowDialog()
    $f.Dispose()
    $iconFont.Dispose()
}

# ---------- Tam dung khi hop / trinh chieu ----------
# Teams dang dung micro hoac camera = dang trong cuoc hop/cuoc goi.
# Windows ghi trang thai nay vao registry: LastUsedTimeStop = 0 nghia la thiet bi dang duoc dung.
function Test-TeamsInCall {
    $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
    foreach ($dev in 'microphone', 'webcam') {
        $keys = @(Get-ChildItem "$base\$dev" -ErrorAction SilentlyContinue) +
                @(Get-ChildItem "$base\$dev\NonPackaged" -ErrorAction SilentlyContinue)
        foreach ($k in $keys) {
            if ($k.PSChildName -notmatch 'teams') { continue }
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.LastUsedTimeStart -gt 0 -and $p.LastUsedTimeStop -eq 0) { return $true }
        }
    }
    $false
}

# Tra ve ly do tam dung tu dong, hoac $null neu duoc hien bai tap
function Get-PauseReason {
    try { if (Test-TeamsInCall) { return 'đang họp Teams' } } catch { }
    if ($script:HasNative) {
        $st = 0
        if ([VsNative]::SHQueryUserNotificationState([ref]$st) -eq 0) {
            if ($st -eq 1) { return 'máy đang khóa' }
            if ($st -in 2, 3, 4) { return 'đang trình chiếu / toàn màn hình' }
        }
    }
    $null
}

# ---------- Tam dung / Tiep tuc on tap (thu cong) ----------
$script:Paused = $false
function Switch-Pause {
    $script:Paused = -not $script:Paused
    if ($script:Paused) {
        $script:PauseItem.Text = '▶  Tiếp tục ôn tập'
        $script:Tray.Text = 'Vocab Saver - đã tạm dừng ôn tập'
        Show-Tip 'Đã tạm dừng ôn tập' 'Bài tập sẽ không tự hiện. Ctrl+C vẫn lưu từ như bình thường.'
    } else {
        $script:PauseItem.Text = '⏸  Tạm dừng ôn tập'
        $script:Tray.Text = 'Vocab Saver'
        $script:QuizTimer.Stop(); $script:QuizTimer.Start()      # dem lai tu dau tu luc tiep tuc
        Show-Tip 'Đã tiếp tục ôn tập' "Bài tập tiếp theo sau $($script:QuizMinutes) phút."
    }
}

# ---------- Doi khoang thoi gian on tap ----------
function Show-IntervalDialog {
    $script:Theme = Get-Theme
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Thời gian ôn tập'; $f.FormBorderStyle = 'FixedDialog'; $f.StartPosition = 'CenterScreen'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true
    $f.ClientSize = '320,150'; $f.Font = New-Object Drawing.Font('Segoe UI', 10)
    $f.BackColor = $Theme.Bg; $f.ForeColor = $Theme.Text

    $l = New-Object Windows.Forms.Label; $l.Text = 'Hiện bài tập mỗi (phút, từ 1 đến 240):'
    $l.Location = '16,16'; $l.AutoSize = $true
    $n = New-Object Windows.Forms.NumericUpDown
    $n.Minimum = 1; $n.Maximum = 240; $n.Value = $script:QuizMinutes
    $n.Location = '16,44'; $n.Width = 100
    $n.BackColor = $Theme.Input; $n.ForeColor = $Theme.Text
    $u = New-Object Windows.Forms.Label; $u.Text = 'phút'; $u.Location = '124,47'; $u.AutoSize = $true

    $ok = New-ThemedButton 'Lưu' $true;  $ok.Location = '126,100'; $ok.Size = '86,34'; $ok.DialogResult = 'OK'
    $no = New-ThemedButton 'Hủy' $false; $no.Location = '218,100'; $no.Size = '86,34'; $no.DialogResult = 'Cancel'
    $f.Controls.AddRange(@($l, $n, $u, $ok, $no))
    $f.AcceptButton = $ok; $f.CancelButton = $no
    $f.Add_Shown({ param($s, $e) Set-TitleBar $s; $s.Activate() })

    if ($f.ShowDialog() -eq 'OK') {
        $script:QuizMinutes = [int]$n.Value
        Save-Settings
        $script:QuizTimer.Interval = $script:QuizMinutes * 60 * 1000      # doi Interval = dem lai tu dau
        $script:IntervalItem.Text = "⏱  Thời gian ôn tập: $($script:QuizMinutes) phút..."
        $msg = if ($script:Paused) { 'Đang tạm dừng. Bấm Tiếp tục ôn tập để chạy lại.' } else { "Bài tập tiếp theo sau $($script:QuizMinutes) phút." }
        Show-Tip "Đã đổi: ôn tập mỗi $($script:QuizMinutes) phút" $msg
    }
    $f.Dispose()
}

# ---------- Tray icon ----------
$script:Tray = New-Object Windows.Forms.NotifyIcon
$script:Tray.Icon = [Drawing.SystemIcons]::Information
$script:Tray.Text = 'Vocab Saver'
$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Làm bài ngay', $null, { Show-Quiz -Manual })
$script:PauseItem = $menu.Items.Add('⏸  Tạm dừng ôn tập', $null, { Switch-Pause })
$script:IntervalItem = $menu.Items.Add("⏱  Thời gian ôn tập: $QuizMinutes phút...", $null, { Show-IntervalDialog })
[void]$menu.Items.Add('Danh sách từ', $null, { Show-List })
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('Thoát', $null, { [Windows.Forms.Application]::Exit() })
$script:Tray.ContextMenuStrip = $menu
$script:Tray.Add_DoubleClick({ Show-List })
$script:Tray.Visible = $true

# ---------- Theo doi clipboard ----------
try { $script:LastClip = [Windows.Forms.Clipboard]::GetText() } catch { $script:LastClip = '' }
$clipTimer = New-Object Windows.Forms.Timer
$clipTimer.Interval = 700
$clipTimer.Add_Tick({
    try { $t = [Windows.Forms.Clipboard]::GetText() } catch { return }   # clipboard dang bi app khac khoa
    if ($t -ceq $script:LastClip) { return }
    $script:LastClip = $t
    $t = ($t.Trim() -replace '\s+', ' ')
    if ($t -cmatch $WordRe) { Add-Word $t }
})
$clipTimer.Start()

$retryTimer = New-Object Windows.Forms.Timer
$retryTimer.Interval = 3 * 60 * 1000
$retryTimer.Add_Tick({
    $pending = @($script:Words | Where-Object { -not $_.meaning } | Select-Object -First 5)
    if (-not $pending) { return }
    $done = @()
    foreach ($w in $pending) {
        try { $w.meaning = Get-Translation $w.word } catch { break }      # van loi thi doi lan sau
        if (-not $w.phonetic)   { $w.phonetic = Get-Phonetic $w.word }
        if (-not $w.definition) { $w.definition = Get-Definition $w.word }
        $done += "$($w.word): $($w.meaning)"
    }
    if ($done) { Save-Words; Show-Tip "Đã dịch xong $($done.Count) từ" ($done -join "`n") }
})
$retryTimer.Start()

$script:QuizTimer = New-Object Windows.Forms.Timer
$script:QuizTimer.Interval = $script:QuizMinutes * 60 * 1000
$script:QuizTimer.Add_Tick({
    if ($script:Paused) { return }                       # nguoi dung tu tam dung
    $why = Get-PauseReason
    if ($why) { $script:Tray.Text = "Vocab Saver - tạm dừng ($why)"; return }
    $script:Tray.Text = 'Vocab Saver'
    Show-Quiz
})
$script:QuizTimer.Start()

Show-Tip 'Vocab Saver đang chạy' 'Bôi đen từ tiếng Anh rồi Ctrl+C để lưu.'
[Windows.Forms.MessageBox]::Show("Vocab Saver đã chạy.`r`n`r`nBôi đen từ tiếng Anh rồi Ctrl+C để lưu.`r`nChuột phải icon (i) ở khay hệ thống để mở menu.", 'Vocab Saver') | Out-Null
[Windows.Forms.Application]::Run()

$clipTimer.Stop(); $retryTimer.Stop(); $script:QuizTimer.Stop()
if ($script:Synth) { $script:Synth.Dispose() }
$script:Tray.Visible = $false
$script:Tray.Dispose()
$mutex.ReleaseMutex()
