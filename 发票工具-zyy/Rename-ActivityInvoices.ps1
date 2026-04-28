param(
    [string]$Path = ".",
    [string]$Person = "",
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Person)) {
    $Person = -join ([char[]](0x5F20, 0x4E09))
}

$voucherLabel = -join ([char[]](0x51ED, 0x8BC1))
$invoiceLabel = -join ([char[]](0x53D1, 0x7968))
$script:OcrReady = $false
$script:OcrEngine = $null
$script:AsTaskGeneric = $null

function Get-NaturalKey {
    param([string]$Text)
    return [regex]::Replace($Text, '\d+', { param($m) $m.Value.PadLeft(20, '0') })
}

function Convert-AmountKey {
    param([string]$AmountText)
    return ([decimal]$AmountText).ToString("0.##")
}

function Get-AmountTextFromName {
    param([string]$FileName)

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $suffixMatch = [regex]::Match($baseName, '-(\d+(?:\.\d{1,2})?)$')
    if ($suffixMatch.Success) {
        return $suffixMatch.Groups[1].Value
    }

    $matches = [regex]::Matches($baseName, '(?<!\d)(\d+\.\d{1,2})(?!\d)')
    if ($matches.Count -eq 0) {
        return $null
    }

    return $matches[$matches.Count - 1].Groups[1].Value
}

function Normalize-OcrText {
    param([string]$Text)

    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $Text.ToCharArray()) {
        $code = [int][char]$char
        if ($code -ge 0xFF10 -and $code -le 0xFF19) {
            [void]$builder.Append([char](0x30 + $code - 0xFF10))
        } elseif ($code -eq 0x00A5 -or $code -eq 0xFFE5) {
            [void]$builder.Append('$')
        } elseif ($code -eq 0xFF0E -or $code -eq 0x00B7 -or $code -eq 0x30FB -or $code -eq 0x2022) {
            [void]$builder.Append('.')
        } else {
            [void]$builder.Append($char)
        }
    }

    return $builder.ToString()
}

function Get-CurrencyAmounts {
    param([string]$Text)

    $normalized = Normalize-OcrText $Text
    $amounts = @()
    $matches = [regex]::Matches($normalized, '\p{Sc}\s*(\d+(?:\s*\.\s*\d{1,2})?)')
    foreach ($match in $matches) {
        $value = ($match.Groups[1].Value -replace '\s+', '')
        $amounts += [pscustomobject]@{
            Text = $value
            Key = Convert-AmountKey $value
            Value = [decimal]$value
        }
    }

    return @($amounts)
}

function New-AmountInfo {
    param([string]$AmountText)

    return [pscustomobject]@{
        Text = $AmountText
        Key = Convert-AmountKey $AmountText
        Value = [decimal]$AmountText
    }
}

function Get-ContextAmounts {
    param(
        [string]$Text,
        [string[]]$Labels,
        [int]$LookAhead = 80
    )

    $normalized = Normalize-OcrText $Text
    $amounts = @()

    foreach ($label in $Labels) {
        $start = 0
        while ($start -lt $normalized.Length) {
            $labelIndex = $normalized.IndexOf($label, $start)
            if ($labelIndex -lt 0) {
                break
            }

            $afterLabel = $normalized.Substring($labelIndex + $label.Length, [Math]::Min($LookAhead, $normalized.Length - $labelIndex - $label.Length))
            $match = [regex]::Match($afterLabel, '(?:\p{Sc}|\$)?\s*(?<!\d)(\d+(?:\s*\.\s*\d{1,2})?)(?!\d)')
            if ($match.Success) {
                $value = ($match.Groups[1].Value -replace '\s+', '')
                $amounts += New-AmountInfo $value
            }

            $start = $labelIndex + $label.Length
        }
    }

    return @($amounts)
}

function New-SummedAmountInfo {
    param(
        [decimal]$Left,
        [decimal]$Right
    )

    return New-AmountInfo (($Left + $Right).ToString("0.##"))
}

function Get-AmountKeyValue {
    param([string]$AmountKey)

    return [decimal]$AmountKey
}

function Get-InferredFreightMatch {
    param(
        [object[]]$ImageInfos,
        [hashtable]$UsedImages,
        [decimal]$InvoiceAmount
    )

    $matches = @()
    foreach ($imageInfo in $ImageInfos) {
        if ($UsedImages.ContainsKey($imageInfo.File.FullName)) {
            continue
        }

        $candidateValues = @($imageInfo.CandidateKeys | ForEach-Object { Get-AmountKeyValue $_ } | Sort-Object -Descending)
        foreach ($candidateValue in $candidateValues) {
            $difference = $InvoiceAmount - $candidateValue
            if ($difference -gt 0 -and $difference -le 30) {
                $matches += [pscustomobject]@{
                    ImageInfo = $imageInfo
                    BaseAmount = $candidateValue
                    Difference = $difference
                }
                break
            }
        }
    }

    return @($matches | Sort-Object Difference, @{ Expression = { Get-NaturalKey $_.ImageInfo.File.Name } })
}

function Get-InvoiceAmounts {
    param([string]$Text)

    $normalized = Normalize-OcrText $Text
    $amounts = @()

    $lowercaseLabel = -join ([char[]](0x5C0F, 0x5199))
    $labelIndex = $normalized.IndexOf($lowercaseLabel)
    if ($labelIndex -ge 0) {
        $afterLabel = $normalized.Substring($labelIndex, [Math]::Min(120, $normalized.Length - $labelIndex))
        $labelMatches = [regex]::Matches($afterLabel, '(?<!\d)(\d+\.\d{2})(?!\d)')
        foreach ($match in $labelMatches) {
            $amounts += New-AmountInfo $match.Groups[1].Value
        }
    }

    if ($amounts.Count -gt 0) {
        return @($amounts)
    }

    $currencyAmounts = @(Get-CurrencyAmounts $normalized)
    if ($currencyAmounts.Count -gt 0) {
        return @($currencyAmounts)
    }

    $decimalMatches = [regex]::Matches($normalized, '(?<!\d)(\d+\.\d{2})(?!\d)')
    foreach ($match in $decimalMatches) {
        $amounts += New-AmountInfo $match.Groups[1].Value
    }

    return @($amounts)
}

function Initialize-Ocr {
    if ($script:OcrReady) {
        return
    }

    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]
    $null = [Windows.Storage.FileAccessMode, Windows.Storage, ContentType=WindowsRuntime]
    $null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType=WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
    $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType=WindowsRuntime]

    $script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1
    })[0]
    $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if ($null -eq $script:OcrEngine) {
        throw "Windows OCR is not available. Install a Windows OCR language pack and try again."
    }

    $script:OcrReady = $true
}

function Wait-WinRt {
    param(
        $Operation,
        [type]$ResultType
    )

    $method = $script:AsTaskGeneric.MakeGenericMethod($ResultType)
    $task = $method.Invoke($null, @($Operation))
    $task.Wait()
    return $task.Result
}

function Get-OcrText {
    param([System.IO.FileInfo]$File)

    Initialize-Ocr

    $storageFile = Wait-WinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($File.FullName)) ([Windows.Storage.StorageFile])
    $stream = Wait-WinRt ($storageFile.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Wait-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap = Wait-WinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $result = Wait-WinRt ($script:OcrEngine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
    return $result.Text
}

function Get-PdfText {
    param([System.IO.FileInfo]$File)

    $pdftotext = Get-Command pdftotext -ErrorAction SilentlyContinue
    if ($null -eq $pdftotext) {
        throw "pdftotext.exe was not found. Install Poppler/Xpdf or make pdftotext available in PATH."
    }

    return (& $pdftotext.Source -layout -enc UTF-8 $File.FullName -) -join "`n"
}

function Get-FileAmountInfo {
    param(
        [System.IO.FileInfo]$File,
        [string]$Kind
    )

    $nameAmount = Get-AmountTextFromName $File.Name
    if ($null -ne $nameAmount) {
        $key = Convert-AmountKey $nameAmount
        return [pscustomobject]@{
            File = $File
            AmountText = $nameAmount
            AmountKey = $key
            CandidateKeys = @($key)
        }
    }

    if ($Kind -eq "invoice") {
        $text = Get-PdfText $File
        $amounts = @(Get-InvoiceAmounts $text)
        if ($amounts.Count -eq 0) {
            throw "Cannot find invoice total amount in PDF text: $($File.Name)"
        }
        $best = $amounts | Sort-Object Value -Descending | Select-Object -First 1
        return [pscustomobject]@{
            File = $File
            AmountText = $best.Text
            AmountKey = $best.Key
            CandidateKeys = @($amounts | ForEach-Object { $_.Key } | Sort-Object -Unique)
        }
    }

    $ocrText = Get-OcrText $File
    $imageAmounts = @(Get-CurrencyAmounts $ocrText)

    $productTotalLabel = -join ([char[]](0x5546, 0x54C1, 0x603B, 0x4EF7))
    $freightLabels = @(
        (-join ([char[]](0x8FD0, 0x8D39))),
        (-join ([char[]](0x90AE, 0x8D39))),
        (-join ([char[]](0x914D, 0x9001, 0x8D39))),
        (-join ([char[]](0x5FEB, 0x9012, 0x8D39)))
    )
    $productTotalAmounts = @(Get-ContextAmounts $ocrText @($productTotalLabel) 80)
    $freightAmounts = @(Get-ContextAmounts $ocrText $freightLabels 50)

    $sumAmounts = @()
    $baseTotalAmounts = $productTotalAmounts
    if ($baseTotalAmounts.Count -eq 0 -and $imageAmounts.Count -gt 0) {
        $baseTotalAmounts = @($imageAmounts | Sort-Object Value -Descending | Select-Object -First 1)
    }

    foreach ($baseTotal in $baseTotalAmounts) {
        foreach ($freightAmount in $freightAmounts) {
            $sumAmounts += New-SummedAmountInfo $baseTotal.Value $freightAmount.Value
        }
    }

    $allImageAmounts = @($imageAmounts + $productTotalAmounts + $freightAmounts + $sumAmounts)
    if ($allImageAmounts.Count -eq 0) {
        throw "Cannot find currency amount by OCR in image: $($File.Name)"
    }

    return [pscustomobject]@{
        File = $File
        AmountText = $allImageAmounts[0].Text
        AmountKey = $allImageAmounts[0].Key
        CandidateKeys = @($allImageAmounts | ForEach-Object { $_.Key } | Sort-Object -Unique)
    }
}

function Get-SafeName {
    param(
        [string]$Folder,
        [string]$FileName,
        [string]$OriginalFullName
    )

    $candidate = Join-Path $Folder $FileName
    if (-not (Test-Path -LiteralPath $candidate) -or $candidate -eq $OriginalFullName) {
        return $FileName
    }

    $nameWithoutExtension = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $extension = [System.IO.Path]::GetExtension($FileName)
    for ($i = 2; $i -lt 1000; $i++) {
        $nextName = "{0}({1}){2}" -f $nameWithoutExtension, $i, $extension
        $nextPath = Join-Path $Folder $nextName
        if (-not (Test-Path -LiteralPath $nextPath)) {
            return $nextName
        }
    }

    throw "Cannot create a non-conflicting file name: $FileName"
}

$target = (Resolve-Path -LiteralPath $Path).Path
$files = @(Get-ChildItem -LiteralPath $target -File)

if ($files.Count -eq 0) {
    throw "No files found in: $target"
}

$imageExtensions = @(".jpg", ".jpeg", ".png", ".bmp", ".webp")
$invoiceExtensions = @(".pdf")

$images = @($files | Where-Object { $imageExtensions -contains $_.Extension.ToLowerInvariant() } | Sort-Object @{ Expression = { Get-NaturalKey $_.Name } })
$invoices = @($files | Where-Object { $invoiceExtensions -contains $_.Extension.ToLowerInvariant() } | Sort-Object @{ Expression = { Get-NaturalKey $_.Name } })

if ($images.Count -eq 0 -or $invoices.Count -eq 0) {
    throw "The folder must contain both product screenshots and invoice PDF files. Images: $($images.Count), invoices: $($invoices.Count)."
}

if ($images.Count -lt $invoices.Count) {
    throw "Not enough images for invoices. Images: $($images.Count), invoices: $($invoices.Count)."
}

if ($images.Count -ne $invoices.Count) {
    Write-Host "Image and invoice counts are different. Images: $($images.Count), invoices: $($invoices.Count). Extra unmatched files will be left unchanged."
}

Write-Host "Reading invoice amounts..."
$invoiceInfos = @()
foreach ($invoice in $invoices) {
    $invoiceInfos += Get-FileAmountInfo $invoice "invoice"
}

Write-Host "Reading image amounts..."
$imageInfos = @()
$imageReadErrors = @()
foreach ($image in $images) {
    try {
        $imageInfos += Get-FileAmountInfo $image "image"
    } catch {
        $imageReadErrors += [pscustomobject]@{
            Name = $image.Name
            Reason = $_.Exception.Message
        }
        Write-Host "Skipping image without readable amount: $($image.Name)"
    }
}

$usedImages = @{}
$pairs = @()
foreach ($invoiceInfo in ($invoiceInfos | Sort-Object @{ Expression = { Get-NaturalKey $_.File.Name } })) {
    $matches = @($imageInfos | Where-Object {
        -not $usedImages.ContainsKey($_.File.FullName) -and ($_.CandidateKeys -contains $invoiceInfo.AmountKey)
    } | Sort-Object @{ Expression = { Get-NaturalKey $_.File.Name } })

    if ($matches.Count -eq 0) {
        $inferredFreightMatches = @(Get-InferredFreightMatch $imageInfos $usedImages (Get-AmountKeyValue $invoiceInfo.AmountKey))
        if ($inferredFreightMatches.Count -gt 0) {
            $bestInferredFreightMatch = $inferredFreightMatches[0]
            Write-Host ("Matched invoice {0} by inferred freight: invoice {1} = image {2} + freight {3:0.##}" -f $invoiceInfo.File.Name, $invoiceInfo.AmountKey, $bestInferredFreightMatch.BaseAmount, $bestInferredFreightMatch.Difference)
            $matches = @($bestInferredFreightMatch.ImageInfo)
        } else {
            $candidates = ($imageInfos | ForEach-Object { "$($_.File.Name):$($_.CandidateKeys -join '/')" }) -join "; "
            throw "Cannot match invoice $($invoiceInfo.File.Name) amount $($invoiceInfo.AmountKey) to any image. Image candidates: $candidates"
        }
    }

    $imageInfo = $matches[0]
    $usedImages[$imageInfo.File.FullName] = $true
    $pairs += [pscustomobject]@{
        AmountText = $invoiceInfo.AmountKey
        AmountKey = $invoiceInfo.AmountKey
        Image = $imageInfo.File
        Invoice = $invoiceInfo.File
    }
}

$unusedImages = @($images | Where-Object { -not $usedImages.ContainsKey($_.FullName) })

$orderedPairs = @($pairs | Sort-Object @{ Expression = { Get-NaturalKey $_.Invoice.Name } }, @{ Expression = { Get-NaturalKey $_.Image.Name } })
$changes = @()

for ($i = 0; $i -lt $orderedPairs.Count; $i++) {
    $index = $i + 1
    $pair = $orderedPairs[$i]
    $amount = $pair.AmountText

    $newImageName = Get-SafeName $target ("{0}{1}{2}-{3}{4}" -f $Person, $voucherLabel, $index, $amount, $pair.Image.Extension.ToLowerInvariant()) $pair.Image.FullName
    $newInvoiceName = Get-SafeName $target ("{0}{1}{2}-{3}{4}" -f $Person, $invoiceLabel, $index, $amount, $pair.Invoice.Extension.ToLowerInvariant()) $pair.Invoice.FullName

    $changes += [pscustomobject]@{
        Type = "voucher"
        Amount = $amount
        OldName = $pair.Image.Name
        NewName = $newImageName
        FullName = $pair.Image.FullName
    }
    $changes += [pscustomobject]@{
        Type = "invoice"
        Amount = $amount
        OldName = $pair.Invoice.Name
        NewName = $newInvoiceName
        FullName = $pair.Invoice.FullName
    }
}

$pendingChanges = @($changes | Where-Object { $_.OldName -ne $_.NewName })

if ($pendingChanges.Count -eq 0) {
    Write-Host "All file names already match the rule. No rename needed."
    exit 0
}

Write-Host "Target folder: $target"
Write-Host "Pairs to process: $($orderedPairs.Count)"
$totalAmount = ($orderedPairs | Measure-Object -Property AmountKey -Sum).Sum
Write-Host ("Matched invoice total: {0:0.00}" -f $totalAmount)
$changes | Select-Object Type, Amount, OldName, NewName | Format-Table -AutoSize

if ($unusedImages.Count -gt 0) {
    Write-Host "Unmatched images left unchanged:"
    $unusedImages | Select-Object Name | Format-Table -AutoSize
}

if ($imageReadErrors.Count -gt 0) {
    Write-Host "Images skipped because OCR could not read an amount:"
    $imageReadErrors | Select-Object Name, Reason | Format-Table -AutoSize
}

if (-not $Apply) {
    Write-Host ""
    Write-Host "Preview only. No files were renamed. To apply, run:"
    Write-Host "powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Path `"$target`" -Person `"$Person`" -Apply"
    exit 0
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $target ("rename-log-{0}.csv" -f $timestamp)
$changes | Export-Csv -LiteralPath $logPath -NoTypeInformation -Encoding UTF8

$tempMoves = @()
foreach ($change in $pendingChanges) {
    $tempName = ".rename-tmp-{0}-{1}{2}" -f $timestamp, ([guid]::NewGuid().ToString("N")), ([System.IO.Path]::GetExtension($change.OldName))
    Rename-Item -LiteralPath $change.FullName -NewName $tempName
    $tempMoves += [pscustomobject]@{
        TempPath = Join-Path $target $tempName
        NewName = $change.NewName
    }
}

foreach ($move in $tempMoves) {
    Rename-Item -LiteralPath $move.TempPath -NewName $move.NewName
}

Write-Host "Rename complete. Log: $logPath"
