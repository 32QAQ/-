# 活动发票重命名工具

`Rename-ActivityInvoices.ps1` 用于批量整理活动报销材料。脚本会读取同一文件夹中的商品截图凭证图片和发票 PDF，按金额自动配对，并重命名为统一格式。演示视频:https://www.bilibili.com/video/BV1G69UBZEhM/?spm_id_from=333.1387.homepage.video_card.click&vd_source=b89188ace0b60eba765b58fc2b387c1d

## 功能

- 自动识别发票 PDF 中的金额。
- 自动识别截图图片中的金额。
- 按金额的有效数字匹配凭证图片和发票 PDF，例如 `208.40` 会按 `208.4` 处理。
- 图片只识别到商品总价、漏识别运费时，会尝试用合理运费差额进行备用匹配。
- 默认只预览改名结果，不会直接修改文件。
- 使用 `-Apply` 参数后才执行重命名。
- 执行重命名时会生成 CSV 日志，方便核对。
- 如果目标文件名已存在，会自动追加 `(2)`、`(3)` 等后缀避免覆盖。

## 文件要求

目标文件夹中需要同时包含：

- 商品截图或付款凭证图片：`.jpg`、`.jpeg`、`.png`、`.bmp`、`.webp`
- 发票文件：`.pdf`

图片数量不能少于发票数量。如果图片比发票多，多出的图片会保持原样。

## 演示文件名

当前文件夹里的演示材料已经改成无意义文件名，例如：

```text
hqxvnr.jpg
qlmzvx.jpg
rpkqta.jpg
wnyjtc.jpg
bqnrte.pdf
ksvmop.pdf
ptzqmf.pdf
xjcwla.pdf
```

这些文件名不包含人员、类型、序号或金额，适合演示脚本如何从图片和 PDF 内容中自动识别金额、匹配凭证和发票，并预览最终规范文件名。

## 依赖环境

1. Windows PowerShell。
2. Windows OCR 功能可用，并已安装可识别图片金额的 OCR 语言包。
3. `pdftotext.exe` 已安装并加入 `PATH`。

`pdftotext.exe` 可通过 Poppler 或 Xpdf 获取。脚本依赖它读取 PDF 发票文本。

## 命名规则

默认人员名称为：

```text
张三
```

重命名后的格式为：

```text
张三凭证序号-金额.图片扩展名
张三发票序号-金额.pdf
```

金额会统一保留有效数字，去掉末尾无效的 `0`。例如 `208.40` 会写成 `208.4`，`99.00` 会写成 `99`。

示例：

```text
张三凭证1-128.5.jpg
张三发票1-128.5.pdf
张三凭证2-99.png
张三发票2-99.pdf
```

如果通过 `-Person` 指定人员名称，则会使用指定名称作为前缀。

## 使用方法

在当前文件夹预览重命名结果：

```powershell
powershell -ExecutionPolicy Bypass -File .\Rename-ActivityInvoices.ps1
```

预览指定文件夹：

```powershell
powershell -ExecutionPolicy Bypass -File .\Rename-ActivityInvoices.ps1 -Path "C:\path\to\folder"
```

指定人员名称并预览：

```powershell
powershell -ExecutionPolicy Bypass -File .\Rename-ActivityInvoices.ps1 -Path "C:\path\to\folder" -Person "张三"
```

确认预览结果无误后，执行重命名：

```powershell
powershell -ExecutionPolicy Bypass -File .\Rename-ActivityInvoices.ps1 -Path "C:\path\to\folder" -Person "张三" -Apply
```

## 运行流程

1. 扫描目标文件夹中的图片和 PDF。
2. 从 PDF 文件名或 PDF 文本中提取发票金额。
3. 从图片文件名或 OCR 识别结果中提取凭证金额。
4. 按金额有效数字匹配发票和凭证图片。
5. 如果精确匹配失败，尝试用图片中的商品总价加合理运费差额匹配。
6. 输出即将重命名的文件列表。
7. 未带 `-Apply` 时停止，只做预览。
8. 带 `-Apply` 时写入重命名日志并执行改名。

## 日志文件

执行重命名后，脚本会在目标文件夹生成日志：

```text
rename-log-年月日-时分秒.csv
```

日志中包含文件类型、金额、原文件名、新文件名和文件路径。

## 常见问题

### 提示找不到 `pdftotext.exe`

说明系统中没有安装 Poppler/Xpdf，或者 `pdftotext.exe` 没有加入 `PATH`。安装后重新打开 PowerShell 再运行脚本。

### 提示 Windows OCR 不可用

需要在 Windows 设置中安装 OCR 相关语言包，然后重新运行脚本。

### 提示无法匹配某张发票金额

可能原因：

- 图片金额识别失败。
- 发票金额和图片金额不一致。
- 图片过于模糊或金额区域不清楚。
- 文件名中已有金额但金额格式不规范。

可以先手动检查脚本输出的候选金额，再调整文件或图片清晰度后重新运行。

如果确认某张图片就是对应发票，但 OCR 没有识别出正确金额，可以把正确金额写进图片文件名。脚本会优先读取文件名中的金额，而不是 OCR 结果。

例如发票金额是 `208.40`，对应图片是 `12321312321.jpg`，可以先把图片改名为：

```text
12321312321-208.40.jpg
```

然后重新运行预览命令：




```powershell
powershell -ExecutionPolicy Bypass -File .\Rename-ActivityInvoices.ps1
```

### 只想测试，不想真的改名

不要加 `-Apply` 参数即可。脚本默认是预览模式，不会重命名任何文件。
