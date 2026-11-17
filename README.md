# SSHKeyForAgent

用三支腳本，快速讓本機上的 AI Agent（Claude Code、Codex CLI 等）能以 **SSH 金鑰免密碼** 登入遠端 Windows 或 Linux 主機。

Agent 無法在互動式密碼提示中輸入密碼，因此需要事先設好金鑰登入；設定完成後，Agent 只要執行 `ssh <別名> <指令>` 即可操作遠端主機。

## 三支腳本

| 腳本 | 在哪裡執行 | 權限 | 用途 |
|---|---|---|---|
| `New-SshKey.ps1` | **本機**（Agent 所在的 Windows） | 一般使用者（不要用系統管理員） | 為每台目標主機產生一把專用金鑰、寫入 `~/.ssh/config`，並印出要在遠端執行的完整指令 |
| `Enable-SshKeyLogin.ps1` | **遠端 Windows** 主機 | 系統管理員（PowerShell 7） | 安裝／啟動 OpenSSH Server、把公鑰放進正確的 authorized_keys、設定 ACL 與防火牆 |
| `enable-ssh-key-login.sh` | **遠端 Linux** 主機 | `sudo` | 安裝 openssh-server（若缺）、加入公鑰、確保開啟公鑰登入、重啟服務 |

**不帶參數直接執行也可以**：兩支 PowerShell 腳本會在執行時詢問缺少的必要資料（見各節說明）。Linux 腳本則必須帶參數，未帶時會顯示用法後結束。

## 需求

- 本機：Windows、PowerShell 7（`winget install Microsoft.PowerShell`）、OpenSSH Client（`ssh-keygen`）。
- 遠端 Windows：PowerShell 7、系統管理員權限；登入帳號必須已在該機器登入過一次（要有使用者設定檔）。
- 遠端 Linux：`bash`、`systemd`；套件管理器為 `apt-get` 或 `dnf`（其他發行版需先自行安裝 openssh-server）。

Windows 上的 OpenSSH（Client 與 Server）來自 [Win32-OpenSSH](https://github.com/PowerShell/Win32-OpenSSH)。`Enable-SshKeyLogin.ps1` 在遠端找不到 `sshd` 服務時，會從 Win32-OpenSSH 的最新 Release 下載 MSI 安裝；只有下載不到時才改裝 Windows 內建版本。已經有 `sshd`（任何版本）就直接沿用、不重裝。

兩支 PowerShell 腳本若在 Windows PowerShell 5.1 中啟動，會自動改用 `pwsh` 重新執行；找不到 `pwsh` 時會停止並提示安裝方式。

## 使用流程

### 1. 本機：產生金鑰

```powershell
pwsh .\New-SshKey.ps1 -Target 192.168.10.20 -User admin -Alias lab-win
```

參數都可省略，直接執行 `pwsh .\New-SshKey.ps1` 時會逐一詢問（直接按 Enter 採用預設值；Target 必填，空白會重問）：

| 參數 | 說明 | 預設 |
|---|---|---|
| `-Target` | 遠端主機名稱或 IP（必填） | — |
| `-User` | 遠端登入帳號，可用 `name`、`DOMAIN\name`、`name@domain` | 本機使用者名稱 |
| `-Alias` | 之後 `ssh <別名>` 用的短名稱 | 與 Target 相同 |

腳本會：

1. 產生 `~/.ssh/id_ed25519_<別名>`（ed25519、無密碼），**已存在就不覆寫**，並把私鑰 ACL 鎖成只有自己可讀。
2. 在 `~/.ssh/config` 加入 `Host <別名>` 區段（`HostName`、`User`、`IdentityFile`、`IdentitiesOnly yes`）；同名區段已存在則不更動。
3. 印出公鑰，以及要貼到遠端 Windows 或 Linux 執行的整行指令。

> 私鑰只留在本機，絕不複製到遠端；只有 `.pub` 那一行公鑰需要帶過去。

### 2a. 遠端 Windows

把 `Enable-SshKeyLogin.ps1` 複製到遠端，以系統管理員身分開啟 PowerShell 7，執行步驟 1 印出的指令，例如：

```powershell
& .\Enable-SshKeyLogin.ps1 -User 'admin' -PublicKey 'ssh-ed25519 AAAA... user-at-PC-for-lab-win'
```

| 參數 | 說明 |
|---|---|
| `-PublicKey` | 步驟 1 印出的公鑰（必填） |
| `-User` | 要登入的帳號（必填） |
| `-KeyFile` | `Auto`（預設）／`Admin`／`User`，決定公鑰寫入哪個檔案 |
| `-AllowFrom` | 選用，逗號分隔的來源 IP 或網段，例如 `192.168.10.12,10.10.0.0/24` |

直接執行 `.\Enable-SshKeyLogin.ps1` 不帶參數時，PowerShell 會依序提示輸入 `PublicKey`（貼上步驟 1 印出的整行公鑰）與 `User`。`-KeyFile`、`-AllowFrom` 不會詢問，未指定時分別採用 `Auto` 與「不限制來源」。

腳本會依序：

1. 沒有 `sshd` 服務才安裝 OpenSSH Server：
   - 優先從 [Win32-OpenSSH 最新 Release](https://github.com/PowerShell/Win32-OpenSSH/releases/latest) 下載符合本機架構的 MSI（`OpenSSH-Win64/ARM64/Win32-v*.msi`），以 GitHub 提供的 SHA256 核對後靜默安裝。
   - 無法連上 GitHub、找不到對應檔案或 SHA256 核對失敗時，才改裝 Windows 內建版本（Windows capability）。
   - 安裝後設為自動啟動並啟動。
2. 解析帳號 SID，判斷是否為本機 Administrators 成員。
3. 寫入公鑰（ASCII、不重複）並鎖定 ACL：
   - 帳號是系統管理員且 `sshd_config` 使用 `administrators_authorized_keys` → 寫入 `%ProgramData%\ssh\administrators_authorized_keys`
   - 其他情況 → 寫入該帳號的 `%USERPROFILE%\.ssh\authorized_keys`
   - 若帳號只是透過網域或巢狀群組成為管理員，`Auto` 可能判斷錯誤，請改用 `-KeyFile Admin` 重跑。
4. 確保防火牆有開放 TCP 22 的入站規則；有 `-AllowFrom` 時把該規則限縮到指定來源（**其他已開放 22 埠的規則仍然有效**）。
5. 若有安裝 PowerShell 7，把 SSH 預設 shell 設為 `pwsh.exe`，然後重啟 `sshd`。

### 2b. 遠端 Linux

把 `enable-ssh-key-login.sh` 複製到遠端，執行步驟 1 印出的指令：

```bash
chmod +x enable-ssh-key-login.sh
sudo ./enable-ssh-key-login.sh admin 'ssh-ed25519 AAAA... user-at-PC-for-lab-linux' [allow-from-cidr]
```

此腳本**不會**詢問：帳號與公鑰兩個參數都必須帶，少於兩個時會顯示用法後結束。第三個參數（允許的來源網段）可省略。

腳本會依序：

1. 沒有 `sshd` 才用 `apt-get` 或 `dnf` 安裝 openssh-server。
2. 建立 `~/.ssh`（700）與 `authorized_keys`（600），加入公鑰（不重複），SELinux 主機會執行 `restorecon`。
3. 若 `PubkeyAuthentication` 未開啟，寫入 `/etc/ssh/sshd_config.d/10-pubkey.conf`（沒有 `sshd_config.d` include 時會提示手動設定）。**密碼登入設定不會被更動。**
4. 先用 `sshd -t` 檢查設定，通過才啟用並重啟服務（`ssh` 或 `sshd`）。
5. 有第三個參數時，在 ufw 或 firewalld（須為啟用中）**新增**一條允許該來源連 22 埠的規則。這只是加一條允許規則，**不會**封鎖其他來源；兩者都未啟用則忽略。

> 本腳本必須是 LF 換行。若從 Windows 複製過去後出現 `$'\r': command not found` 或 `invalid option name`，請先執行 `sed -i 's/\r$//' enable-ssh-key-login.sh`。

### 3. 測試

回到本機：

```powershell
ssh lab-win
```

能直接登入、不問密碼即完成。之後 Agent 就能這樣使用：

```powershell
ssh lab-win "Get-Service sshd"
ssh lab-linux "uname -a"
```

## 安全注意事項

- 金鑰沒有密碼保護（Agent 才能無人值守使用），**任何能讀取本機私鑰的人都能登入遠端**。請只在受信任的機器上使用，並維持腳本設定的 ACL。
- 每台目標主機一把金鑰；要撤銷某台的存取權，只需從該主機的 authorized_keys 刪除對應那一行（行尾註解為 `<本機使用者>-at-<電腦名稱>-for-<別名>`）。
- 建議讓 Agent 使用權限最小的帳號，非必要不要用系統管理員或 root。
- 腳本都可重複執行：已存在的金鑰、設定區段、公鑰行都不會重複加入或被覆寫。
