param([string]$Binary = "$PSScriptRoot\..\..\target\desktop\ClipasteTray.exe")
# Opt-in Windows desktop test. It temporarily copies fixtures and restores the clipboard.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run with pwsh -STA.' }
$null = [Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($Binary))
$original = [Windows.Forms.Clipboard]::GetDataObject()
$saved = [Windows.Forms.DataObject]::new()
if ($null -ne $original) {
    foreach ($format in $original.GetFormats($false)) {
        $value = $original.GetData($format, $false)
        if ($value -is [Drawing.Image]) { $value = $value.Clone() }
        if ($value -is [IO.MemoryStream]) { $value = [IO.MemoryStream]::new($value.ToArray()) }
        if ($null -ne $value) { $saved.SetData($format, $false, $value) }
    }
}
$form = [ClipasteDesktop.Dashboard]::new($null, $null, $null)
$bitmap = [Drawing.Bitmap]::new(640, 240)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$font = [Drawing.Font]::new('Segoe UI', 24)
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
function Field($name) { $form.GetType().GetField($name, $flags).GetValue($form) }
function Pump {
    for ($i=0; $i -lt 12; $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
}
try {
    $form.Show()
    [Windows.Forms.Clipboard]::SetText('Clipaste preview test — text remains text.')
    Pump
    if ((Field textPreview).Text -ne 'Clipaste preview test — text remains text.') { throw 'Text preview did not update through the clipboard listener.' }
    if ((Field imagePreview).Visible) { throw 'Image preview remained visible after text copy.' }
    $graphics.Clear([Drawing.Color]::White)
    $graphics.FillEllipse([Drawing.Brushes]::Orange, 30, 30, 160, 160)
    $graphics.DrawString('Clipboard image preview', $font, [Drawing.Brushes]::MidnightBlue, 205, 85)
    [Windows.Forms.Clipboard]::SetImage($bitmap)
    Pump
    if ((Field imagePreview).Image.Width -ne 640 -or -not (Field imagePreview).Visible) { throw 'Image preview did not update through the clipboard listener.' }
    if ((Field textPreview).Text) { throw 'Old text remained in the preview.' }
    (Field timer).Stop()
    $list = Field hosts
    $null = $list.Items.Add([Windows.Forms.ListViewItem]::new([string[]]@('stssgoffmgt01-rh8','connected','18340','')))
    $null = $list.Items.Add([Windows.Forms.ListViewItem]::new([string[]]@('sgxmgt01-rh8','connected','18340','')))
    (Field summary).Text = '2 of 2 hosts connected · clipboard stays on this PC until requested'
    $render = [IO.Path]::GetFullPath("$PSScriptRoot\..\..\target\desktop\preview.png")
    $form.Render($render)
    $form.Close()
    if ($form.IsDisposed -or $form.Visible) { throw 'Closing the dashboard did not hide it to the tray.' }
    'PASS: native clipboard events update text/image preview; old preview clears; close hides to tray.'
    "Preview: $render"
} finally {
    $form.Dispose(); $graphics.Dispose(); $bitmap.Dispose(); $font.Dispose()
    if ($null -eq $original) { [Windows.Forms.Clipboard]::Clear() } else { [Windows.Forms.Clipboard]::SetDataObject($saved, $true) }
}
