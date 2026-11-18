**从刚购买 VPS 开始：Cloudflare 三入口、Xray 与 Windows TUN 新手教程**

版本：2026-11-18。主线：Debian 13 + Xray VLESS / WebSocket / TLS + Cloudflare + Windows 10/11 / FlClash。附 Android Clash Meta、VNC 排错和源站访问加固。

本文与随附模板为公开脱敏版本，不含作者的真实公网地址、源站/出口地址、域名、UUID、证书或设备标识。example.com 是保留示例域名，所有占位符必须替换为读者自己的信息。本文只覆盖 IPv4 主线，不表示完成 IPv6 泄漏验证；实际有 IPv6 的网络需要另外验收。

为了复现已有的 WS 架构，本教程固定编写时可接受该配置的 Xray 版本。该版本会提示 WebSocket 传输已弃用、建议迁移 XHTTP：警告不等于本次配置加载失败，但不能把 WS 当成长期无需维护的方案，更不能以后直接升级最新版而不复测。[Xray WebSocket 文档](https://xtls.github.io/config/transports/websocket.html)

**阅读方式、文件与操作范围**

本教程面向全新、由你管理、尚未部署网站或其他业务的 VPS。已有生产服务时先评估端口、配置与防火墙，不直接套用覆盖命令。使用须符合当地规定和服务商条款。

先完整解压教程包，保留目录结构：

- README.md：本文，含操作、成功标志和排错。
- templates/xray-server.json：完整服务端模板。
- templates/mate-windows.yaml：完整 Windows 模板。
- templates/mate-android.yaml：完整 Android 模板。
- generate-config.ps1：在新目录生成配置，不安装软件、不改网络、不连接服务器。
- 验证说明.md：本教程包实际完成的检查及未验证的范围。
- SHA256SUMS.txt：公开包文件校验值。

脚本生成的 generated 目录包含读者自己的鉴权信息，不应加入公开分享包。

准备两个终端窗口：

- 窗口 A：本机 Windows PowerShell，留在电脑上，用于 SCP、编辑、生成配置和测试。
- 窗口 B：另一个 PowerShell，通过 SSH 登录 VPS 后成为服务器终端。
- 下文“VPS / Bash”只在 B 执行；“Windows PowerShell”只在 A 执行，首次登录示例除外。
- 两窗口的变量不共享。关闭任一窗口后，其中变量需要重新输入。代码块不含终端提示符，可直接复制。

**第 0 步：理解要搭建的网络**

~~~text
Windows 应用 → FlClash / Mihomo TUN → 分流
                                  ├→ 指定直连网站 / 局域网
                                  └→ PROXY fallback：CF-A、CF-B、CF-C
                                               ↓
                                        Cloudflare 边缘
                                               ↓
                                           回源 TLS
                                               ↓
                                          VPS / Xray
                                               ↓
                                            目标网站

DNS → Mihomo DNS → HTTPS DNS #DNS-PROXY → 三个个人节点之一
~~~

三个入口共用同一台 VPS，不是三台独立服务器。使用普通 Cloudflare 代理记录和 WebSocket 回源，不部署 Workers、Cloudflare Tunnel、Nginx 或 Docker。目标网站看到的代理出口仍是 VPS，不是 Cloudflare 边缘地址；直连网站则使用本地出口。

CF 终止客户端一侧的外层 TLS，再建立到源站的独立 TLS。CDN 不等于完全匿名，也不保证源站永远隐藏或可达。

本教程两组 fallback 均不放 DIRECT：三个入口不可用时，不自动把代理规则回退成本地直连；原本明确为 DIRECT 的网站不受影响。这是教程模板的设计，不代表已经修改任何现有个人配置。

**第 1 步：准备工具和参数**

需要：

1. Debian 13 VPS、公网 IPv4、SSH 端口、登录账号及密码或自己的 SSH 私钥。
2. 自己控制的域名、Cloudflare 账号。域名和 VPS 费用自行承担。
3. Windows 10/11、OpenSSH 客户端、curl.exe。
4. VPS 商家的网页控制台/VNC 入口，用于登录失败时恢复。

窗口 A / Windows PowerShell：

~~~powershell
Get-Command ssh.exe, scp.exe, curl.exe
Set-Location (Read-Host '解压后的教程目录完整路径')
$VpsAddress = Read-Host 'VPS 公网 IPv4'
$SshPort = [int](Read-Host 'SSH 端口，通常为 22')
$Domain = (Read-Host '代理子域名，例如 vpn.example.com').Trim()
~~~

成功标志：工具均能列出路径，当前目录能看到本文、generate-config.ps1 与 templates 文件夹。缺少 ssh/scp 时，在 Windows“设置 → 应用 → 可选功能”安装 OpenSSH 客户端，重开 PowerShell 再检查。本文始终用 curl.exe，避免 PowerShell 的 curl 别名影响。

域名不带 https://、端口或路径。

| 参数 | 从哪里取得 | 填在哪里 |
|---|---|---|
| VPS 公网地址 | VPS 商家控制台 | SSH/SCP；Cloudflare A 记录 |
| Domain | 自己的代理子域名 | Cloudflare、证书、客户端 SNI 和 WS Host |
| UUID | 后文由 xray uuid 生成 | 服务端 clients.id、三个客户端 uuid |
| WS_PATH | 后文在 VPS 随机生成 | 服务端与三个客户端的 WS 路径 |
| CF 入口 A/B/C | 自己当前网络下筛选并验证 | 客户端 server、TUN /32 排除、端点 DIRECT 规则 |
| InterfaceAlias | Windows 实际出网网卡名称 | 三个 Windows 节点绑定；Android 不填 |

**第 2 步：首次 SSH 登录与环境检查**

窗口 B / 尚未登录时的 Windows PowerShell：在这个新窗口重新输入 VPS 地址和 SSH 端口，然后登录。

~~~powershell
$VpsAddress = Read-Host 'VPS 公网 IPv4'
$SshPort = [int](Read-Host 'SSH 端口')
ssh.exe -p $SshPort "root@$VpsAddress"
~~~

密码输入时不显示字符，输入后回车。使用密钥时，将最后一条替换为：

~~~powershell
$SshKey = Read-Host '自己的 SSH 私钥完整路径'
ssh.exe -i $SshKey -p $SshPort "root@$VpsAddress"
~~~

首次主机指纹与商家资料或控制台核对。主机密钥改变时，先确认是否重装或换地址，不直接删除记录继续连接。不要公开自己的私钥或完整登录记录。

本教程以 root 初始管理登录为例。商家只给普通管理员时，先用其账号登录，再运行 sudo -i；文件上传先放到该用户家目录，由管理员安装到目标目录。不要为了匹配本文而额外开启 root 密码登录。

窗口 B / VPS Bash：

~~~bash
cat /etc/os-release
uname -m
id
date -u
ss -ltnp '( sport = :443 )'
~~~

成功标志：Debian 13；当前具备 root 管理权限；日期合理；最后一条未显示其他服务占用 443。端口已有服务时停止主线并另行规划，不随意杀进程。

~~~bash
apt update
apt install -y ca-certificates curl openssl unzip python3 ufw
~~~

成功标志：安装正常完成。下载失败先检查 VPS DNS、出网和软件源，不通过关闭 TLS 校验绕过错误。

**第 3 步：域名托管与 Cloudflare**

Cloudflare 控制台：

1. 在合适的注册商购买自己控制的域名，不使用作者的实际域名。
2. 登录 Cloudflare，添加域名并选择适合的计划；本结构不需要额外的隧道产品。
3. 在注册商的域名 NS 设置中，改成 Cloudflare 分配的两条 Nameserver；不是添加两条普通解析记录。
4. 等待 Cloudflare 域名状态变为 Active。未激活时先处理 NS，不急着排查 Xray。
5. DNS → Records 新建 A 记录：名称如 vpn；地址为自己的 VPS 公网 IPv4；Proxy status 为 Proxied 橙色云；TTL 自动。
6. 本 IPv4 主线不额外创建指向源站的未代理同名 AAAA 记录。不要在客户端入口填源站地址。
7. SSL/TLS → Overview，设为 Full (strict)。
8. Network 中确认 WebSockets 开启。
9. 在边缘证书页面等待代理域名的证书 Active。控制台位置更新时按同名功能寻找。

窗口 A / Windows PowerShell：

~~~powershell
$ZoneName = Read-Host '根域名，例如 example.com'
Resolve-DnsName -Name $ZoneName -Type NS
Resolve-DnsName -Name $Domain -Type A
~~~

成功标志：NS 对应 Cloudflare；A 查询返回 CF 代理地址，而非直接返回源站。DNS 结果只是域名检查，不表示 Xray 已搭好。源站还没启动时出现 52x 暂不作为失败结论。

Full (strict) 还要求源站 TLS、证书有效且主机名匹配。[Full (strict) 官方说明](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)、[WebSockets](https://developers.cloudflare.com/network/websockets/)

**第 4 步：防火墙先放行 SSH，再放行 443**

商家“安全组/网络防火墙”放行实际 SSH 端口的 TCP 入站、443/TCP 入站及必要出站。ping 通不代表 TCP 端口通。本入口不需要 UDP/443，不把电脑的 7890 暴露到公网。

以下 UFW 命令只用于前面确认的全新 VPS；已有规则或其他业务时先评估，不执行 ufw reset。

窗口 B / VPS Bash：

~~~bash
SSH_PORT=$(printf '%s\n' "$SSH_CONNECTION" | awk '{print $4}')
printf '当前 SSH 服务端口：%s\n' "$SSH_PORT"
ufw status verbose
~~~

确认端口正确后：

~~~bash
test -n "$SSH_PORT" && test "$SSH_PORT" != 443 || { echo "先核实 SSH 端口，且不能与 HTTPS 入口冲突"; exit 1; }
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp" comment 'SSH-admin'
ufw allow 443/tcp comment 'Xray-origin-initial'
ufw enable
ufw status verbose
~~~

启用前确认已允许 SSH，再回答 y。成功标志：UFW active，SSH 和 443 放行。保留旧 SSH 窗口，在电脑另开窗口再次登录成功后，才关闭旧连接。

VNC 中 SSH_CONNECTION 可能为空，先按附录确认实际端口再手动设置 SSH_PORT，不能照抄空值。

**第 5 步：安装官方 Xray**

编写时基线：Xray v26.11.9、FlClash v0.9.3。固定官方安装器的一次提交，减少主分支更新漂移；基线不是永久最新版本，将来升级前应阅读发行说明并重测。

窗口 B / VPS Bash：

~~~bash
curl -fL --connect-timeout 15 --max-time 120 \
  'https://raw.githubusercontent.com/XTLS/Xray-install/9d3ad49a3294d4c1d042f1fb6a16360b4d1befd1/install-release.sh' \
  -o /root/install-xray.sh
bash -n /root/install-xray.sh
bash /root/install-xray.sh install --version 26.11.9
/usr/local/bin/xray version
systemctl show xray -p User -p Group -p AmbientCapabilities -p ExecStart
systemctl cat xray
~~~

成功标志：安装完成、版本正确；有效服务账户 xray:xray；能力包含 CAP_NET_BIND_SERVICE；配置路径为 /usr/local/etc/xray/config.json。安装器可能启动空配置，这不代表代理已可用。

后续权限命令以这一固定脚本生成的 xray:xray 为前提。实际不同先检查安装来源与 systemd 覆写，不把 nobody 或 xray 机械套用。监听低端口的能力与读取证书的权限是两件事。[官方安装器](https://github.com/XTLS/Xray-install)

~~~bash
systemctl stop xray
test -s /usr/local/share/xray/geoip.dat
test -s /usr/local/share/xray/geosite.dat
~~~

test 成功不输出内容、退出码为 0，可紧接 echo $? 查看。模板使用 geoip:private，不使用省略地理数据的安装参数。

**第 6 步：私钥留在 VPS，Cloudflare 签发证书**

本地生成私钥，只把 CSR 证书请求交给 Cloudflare。先将下面域名改为自己的代理子域名。

窗口 B / VPS Bash：

~~~bash
DOMAIN='vpn.example.com'
install -d -m 750 -o root -g xray /usr/local/etc/xray/cert
umask 077
test ! -e /usr/local/etc/xray/cert/origin.key || { echo "已有私钥，停止以免覆盖"; exit 1; }
openssl req -new -newkey rsa:2048 -nodes \
  -keyout /usr/local/etc/xray/cert/origin.key \
  -out /root/origin.csr \
  -subj "/CN=$DOMAIN" \
  -addext "subjectAltName=DNS:$DOMAIN"
chown root:xray /usr/local/etc/xray/cert/origin.key
chmod 640 /usr/local/etc/xray/cert/origin.key
openssl req -in /root/origin.csr -noout -subject -verify
cat /root/origin.csr
~~~

成功标志：CSR 自检成功、subject 正确；最后显示完整 BEGIN CERTIFICATE REQUEST / END CERTIFICATE REQUEST 块。复制 CSR，不包括命令提示符，不复制 origin.key。

Cloudflare 控制台：

1. SSL/TLS → Origin Server → Create Certificate。
2. 选择 Use my private key and CSR，粘贴 CSR。
3. 主机名覆盖准确的代理子域名；按维护计划选择有效期并记录到期时间。
4. 创建后取得 PEM 格式 Origin Certificate。自带 CSR 流程不需要 Cloudflare 再生成私钥。
5. Origin CA 用于回源，客户端看到的是 CF 边缘证书。不能因浏览器不信任 Origin CA，就关闭客户端证书校验。

窗口 A：用记事本将公有证书保存为教程目录下的 origin.pem，保留完整 BEGIN CERTIFICATE / END CERTIFICATE 两行，不保存成 origin.pem.txt。

~~~powershell
Get-Item .\origin.pem
Get-Content .\origin.pem -First 1
scp.exe -P $SshPort .\origin.pem ('root@{0}:/root/origin.pem' -f $VpsAddress)
~~~

密钥登录者在窗口 A 也定义自己的 $SshKey，并给 scp 增加 -i $SshKey。scp 端口参数大写 -P，ssh 小写 -p。

窗口 B / VPS Bash：

~~~bash
install -o root -g xray -m 640 /root/origin.pem /usr/local/etc/xray/cert/origin.pem
openssl x509 -in /usr/local/etc/xray/cert/origin.pem -noout -subject -issuer -dates -ext subjectAltName
openssl x509 -in /usr/local/etc/xray/cert/origin.pem -noout -checkhost "$DOMAIN"
openssl x509 -in /usr/local/etc/xray/cert/origin.pem -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum
openssl pkey -in /usr/local/etc/xray/cert/origin.key -pubout -outform DER | sha256sum
runuser -u xray -- test -r /usr/local/etc/xray/cert/origin.pem
runuser -u xray -- test -r /usr/local/etc/xray/cert/origin.key
~~~

成功标志：日期和域名正确；两条公钥摘要一致；服务账户读取检查退出码均为 0。root 能读不代表服务账户能读。摘要不同说明证书与密钥不匹配；读取失败则检查父目录、属组和权限，不使用 chmod 777。[Origin CA / 自带 CSR](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)



**第 7 步：生成鉴权参数，配置并启动服务端**

窗口 B / VPS Bash：

~~~bash
UUID=$(/usr/local/bin/xray uuid)
WS_PATH="/$(openssl rand -hex 12)"
export UUID WS_PATH
printf 'UUID=%s\nWS_PATH=%s\n' "$UUID" "$WS_PATH"
~~~

成功标志：得到一个 UUID 和一个以 / 开头的随机路径。保存在自己的私密记录中；后面三个节点共用这两个值。关闭 SSH 后变量会丢失；不要重新生成后忘记同步客户端。

窗口 A / Windows PowerShell，复制刚才两项：

~~~powershell
$Uuid = (Read-Host '粘贴 VPS 生成的 UUID').Trim()
$WsPath = (Read-Host '粘贴 VPS 生成的 WS_PATH，含开头 /').Trim()
scp.exe -P $SshPort .\templates\xray-server.json ('root@{0}:/root/xray-server.template.json' -f $VpsAddress)
~~~

密钥登录给 scp 补 -i $SshKey。成功标志：模板上传完成。此时尚不需要知道三个 CF 入口，避免先后依赖互相卡住。

窗口 B / VPS Bash，填写上传模板并写入候选文件：

~~~bash
export UUID WS_PATH
python3 - <<'PY'
import json, os, re, uuid
from pathlib import Path
node_id = str(uuid.UUID(os.environ["UUID"]))
path = os.environ["WS_PATH"]
if not re.fullmatch(r"/[A-Za-z0-9_-]+", path):
    raise SystemExit("WS_PATH 格式不正确")
text = Path("/root/xray-server.template.json").read_text()
text = text.replace("__UUID__", node_id).replace("__WS_PATH__", path)
if re.search(r"__[A-Z_]+__", text):
    raise SystemExit("仍有占位符，停止")
config = json.loads(text)
Path("/usr/local/etc/xray/config.json.new").write_text(
    json.dumps(config, indent=2) + "\n"
)
PY
chown root:xray /usr/local/etc/xray/config.json.new
chmod 640 /usr/local/etc/xray/config.json.new
runuser -u xray -- env XRAY_LOCATION_ASSET=/usr/local/share/xray \
  /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json.new
~~~

成功标志：最后输出 Configuration OK 且退出码为 0。这里按实际服务账户读取文件，避免只在 root 下通过。若提示 WebSocket deprecated，在本固定版本中是弃用警告；如果是错误或没有 Configuration OK，先排错，不替换正式配置。

验证成功后：

~~~bash
cp -a /usr/local/etc/xray/config.json /root/xray-config.before-tutorial.json
install -o root -g xray -m 640 /usr/local/etc/xray/config.json.new /usr/local/etc/xray/config.json
systemctl daemon-reload
systemctl enable xray
systemctl restart xray
systemctl is-active xray
ss -ltnp '( sport = :443 )'
journalctl -u xray -n 40 --no-pager
~~~

成功标志：active；443 由 xray 监听；日志无证书、权限、配置错误。若重做本步骤，不要覆盖之前有价值的备份，先另选备份名。

完整 JSON 在本文末尾和 templates/xray-server.json 中。其要点：

- VLESS 入站 + WS + TLS，不带 Reality/Vision 的 flow。
- Xray 直接监听 443，读取 Origin 证书与本机私钥，不额外安装 Nginx。
- 默认 freedom 出站；包含私有地址和识别到的 BitTorrent 流量阻止规则。
- 开启必要嗅探辅助协议识别；“匹配到的 BT 被拦截”不等于能阻止一切变体、加密传输或滥用，不能据此保证不会触发服务商政策。
- 私有地址规则依赖 geoip.dat；本例用 IPIfNonMatch 为域名目标提供第二轮 IP 规则匹配，不把所有域名解析细节都归给客户端。[Xray 路由说明](https://xtls.github.io/config/routing.html)

**第 8 步：筛选三个 CF 入口，并逐个验证回源**

这一步在电脑本地网络执行。先关闭本机其他代理客户端、系统代理和 TUN，避免“筛选到的是旧代理到 CF 的路线”。只在你自己的电脑上测速，不在 VPS 上大并发扫描。

方法 A：先查看代理域名当前 A 记录：

~~~powershell
Resolve-DnsName -Name $Domain -Type A |
    Where-Object { $_.IPAddress } |
    Select-Object -ExpandProperty IPAddress -Unique
~~~

通常只能取得少量地址，不一定有三个。它们可作候选，但不代表本地最快。

方法 B：使用 CloudflareSpeedTest 初筛：

1. 打开官方 [XIU2/CloudflareSpeedTest Releases](https://github.com/XIU2/CloudflareSpeedTest/releases)。
2. 普通 Intel/AMD 64 位 Windows 下载 cfst_windows_amd64.zip，ARM 设备选对应架构。编写时核对版本为 v2.3.5，程序名为 cfst.exe。
3. 解压到教程目录下的 cfst 子目录。不要从不明网盘取得修改版程序。
4. 在窗口 A 执行下面命令，以官方 IPv4 段为候选输入，适度并发，只做 TCP 延迟初筛，关闭下载测速。

~~~powershell
Push-Location .\cfst
curl.exe -fL --max-time 30 'https://www.cloudflare.com/ips-v4' -o ip.txt
Get-Content .\ip.txt -First 3
.\cfst.exe -f ip.txt -tp 443 -n 20 -t 4 -dd -p 10 -o result.csv
Pop-Location
$Candidates = Import-Csv -LiteralPath .\cfst\result.csv -Encoding UTF8 |
    Select-Object -First 10 -ExpandProperty 'IP 地址'
$Candidates
~~~

成功标志：ip.txt 是 CIDR 网段文本，程序有成功响应的候选，result.csv 非空。如果文件是 HTML 错误页、没有成功候选，先检查下载及当前网络，不把空表继续当正常结果。

-dn 与 -dd 含义不同；这里使用官方说明中的 -dd 禁止下载测速。TCP 初筛会按当前网络条件变化，不能把别人的结果当作自己的结果，也不要求一定低于某个固定延迟。[项目参数说明](https://github.com/XIU2/CloudflareSpeedTest)

接下来必须对候选执行实际域名的 TLS / WebSocket 测试。以下两种测试分开看：

~~~powershell
$CandidateIp = Read-Host '输入一个候选 CF IPv4'
$ResolveArg = '{0}:443:{1}' -f $Domain, $CandidateIp

# CF 自己返回的诊断页面，仅用于 TLS 接入和机房信息，不证明回源成功。
curl.exe -4 --noproxy '*' --resolve $ResolveArg --max-time 10 "https://$Domain/cdn-cgi/trace"

# 真正的 WS 路径，保存响应头；仍不是完整 VLESS 鉴权测试。
$HeaderFile = Join-Path (Get-Location) ('edge-{0}.headers.txt' -f $CandidateIp)
curl.exe -4 --noproxy '*' --http1.1 --resolve $ResolveArg --max-time 8 -sS -D $HeaderFile -o NUL "https://$Domain$WsPath" -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='
Get-Content -LiteralPath $HeaderFile
~~~

本步骤必须在没有其他 TUN 接管的情况下进行；--noproxy 只排除应用的显式代理，不会绕过系统路由或别的软件 TUN。

成功标志：路径测试的响应头有 101 Switching Protocols。curl 不是 VLESS 客户端，升级后可能等待直至 --max-time 到期；因此“已收到 101 后出现 curl 28”与“连 101 都没收到就超时”不是一回事。此处的 Sec-WebSocket-Key 是协议握手示例随机值，不是你的 VLESS UUID 或服务器私钥。

重复测试其他候选，选三个互不相同、在当前网络下稳定获得 101 的入口。不要按在线 IP 地理库猜机房；CF Anycast 的实际接入可看 trace 的 colo，但也不能只凭地理距离判断整条线路性能。只到 CF 快、回源慢的入口仍可能不好用。

常见结果：

| 结果 | 能说明什么 / 下一步 |
|---|---|
| CF trace 正常 | 电脑到 CF 的这次 HTTPS 连接可用；不证明源站和 WS 正确 |
| WS 101 | TLS、回源及 WS 升级阶段通过；继续做真正代理请求 |
| 400 / 404 | 检查是否用了完整 WS Upgrade 请求、路径、Host 和回源日志；不能直接判定代理成功 |
| 403 / challenge | 检查 CF 安全规则、挑战、WAF 与路径；不要直接关闭整站所有防护 |
| 521 | 检查源站监听、端口与防火墙，不能只靠错误码唯一定位 |
| 522 | 检查源站地址、连接路径、防火墙及服务器负载 |
| 525 / 526 | 检查源站 TLS、证书、私钥匹配、有效期、主机名与 Full (strict) |
| TCP 超时 | 对照当前其他入口和独立网络，再判断是否为特定入口路线问题 |

CF 也可能重启或中断已有 WebSocket，所以需要客户端重连和多入口，而不是认为升级成功后永不断线。

**第 9 步：生成匹配的 Windows、Android、服务端配置**

窗口 A 先检查当前真正出网的物理网卡：

~~~powershell
Get-NetAdapter |
    Where-Object { $_.Status -eq 'Up' } |
    Format-Table Name, InterfaceDescription, ifIndex, Status

Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' |
    Sort-Object RouteMetric |
    Format-Table InterfaceIndex, InterfaceAlias, NextHop, RouteMetric
~~~

选择实际有互联网连接的物理网卡，不选虚拟 TUN、虚拟机或断开的适配器；多网卡同时在线时结合网关和实际路由确认。

~~~powershell
$InterfaceAlias = Read-Host '实际出网物理网卡的 Name'
$EdgeA = (Read-Host '通过 WS 101 检查的 CF 入口 A').Trim()
$EdgeB = (Read-Host '通过 WS 101 检查的 CF 入口 B').Trim()
$EdgeC = (Read-Host '通过 WS 101 检查的 CF 入口 C').Trim()
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\generate-config.ps1 -Domain $Domain -Uuid $Uuid -WsPath $WsPath -EdgeA $EdgeA -EdgeB $EdgeB -EdgeC $EdgeC -InterfaceAlias $InterfaceAlias
Get-ChildItem .\generated
~~~

- ExecutionPolicy Bypass 仅用于这一个脚本进程，不要求永久修改执行策略。
- 脚本只处理教程模板，写入新的 generated 目录。目录存在时会停止，避免覆盖；需要重做时用 -OutputDirectory 指定另一个全新目录。
- 三个入口只支持标准 IPv4；脚本检查语法、UUID、路径、入口重复与占位符，但不替你证明 IP 属于 CF 或线路可用，第 8 步不能省略。
- 本机 $Uuid、$WsPath 必须与第 7 步服务端一致，不能重新生成一套。变量丢失时从自己的私有记录恢复。
- 输出 xray-server.json 与服务端模板使用同一参数，方便核对。服务端已在第 7 步安装完成，这里不需要重复上传或重启。

成功标志：generated 里有 xray-server.json、mate-windows.yaml、mate-android.yaml，且没有 __UUID__ 等未替换占位符：

~~~powershell
Get-ChildItem .\generated -File |
    Select-String -Pattern '__[A-Z_]+__'
Select-String -Path .\generated\mate-windows.yaml -Pattern 'interface-name'
Select-String -Path .\generated\mate-android.yaml -Pattern 'interface-name'
~~~

第一条和最后一条不应输出匹配；Windows 文件应有三个实际网卡绑定。Android 不复制电脑的网卡名。不要把 generated 配置上传到公开仓库。

如果手动填写，请按文末完整模板替换全部占位符。替换 CF 入口时要同时改节点 server、对应的 /32 排除和 IP-CIDR 保护规则；SNI 与 Host 填域名，不能填入口 IP。客户端校验 CF 边缘证书，不使用 skip-cert-verify: true。


**第 10 步：先用显式代理验证完整 VLESS 链路**

从 [FlClash 官方 Releases](https://github.com/chen08209/FlClash/releases) 获取适合系统架构的 Windows 安装包。本教程核对基线为 v0.9.3；安装及提权只对自己可信的官方客户端进行。

先完成一次无其他 VPN/TUN 干扰的本地出口基线记录，再启动 FlClash。基线值只留在自己的私密记录里，不贴到公开评论：

~~~powershell
curl.exe -4 --noproxy '*' --max-time 15 https://api.ipify.org
~~~

在 FlClash：

1. 从文件导入 generated/mate-windows.yaml，并选中这份配置。
2. 使用规则模式。
3. 第一阶段先关闭 TUN 和 Windows 系统代理，但让代理核心运行、本地混合端口监听。
4. 不启用“追加系统 DNS”，不把本模板的 DNS 上游改成本地运营商解析器。若客户端有 DNS/TUN 覆写，检查是否覆盖了模板。
5. 若 7890 已有其他客户端占用，先退出那个客户端；不要让两套核心争用同一端口。
6. fallback 是自动组，不是手动选择组；Android 的显示过滤见附录。

窗口 A / Windows PowerShell：

~~~powershell
Get-NetTCPConnection -State Listen -LocalPort 7890 -ErrorAction SilentlyContinue
curl.exe -4 --proxy http://127.0.0.1:7890 --connect-timeout 10 --max-time 20 -o NUL -sS -w 'HTTP=%{http_code} total=%{time_total}s\n' https://www.gstatic.com/generate_204
curl.exe -4 --proxy http://127.0.0.1:7890 --max-time 20 https://api.ipify.org
~~~

成功标志：

- 7890 由当前 FlClash 核心监听。
- 第一个代理请求返回 HTTP=204。
- 第二个请求看到预期的 VPS 出口。正常公网 VPS 通常与分配地址一致，但商家 NAT/多出口可能不同，可在 VPS 运行 curl -4 https://api.ipify.org 私下核对。
- 客户端日志显示使用 PROXY[CF-A] 或其他个人入口；服务端没有鉴权/证书错误。

这一层实际经过 VLESS 鉴权，比“收到 WS 101”多验证了一步。只有 101、真正代理请求超时，仍要检查 UUID、路径、源站出网、DNS、服务端日志及目标网站；不要通过关闭证书校验掩盖问题。

**逐条验证三个入口的完整鉴权**

上面的请求只验证当时被 fallback 选中的入口。若要记录“三个入口均通过”，还应在 TUN 关闭时逐条测试：

1. 将 generated/mate-windows.yaml 另存为 test-A.yaml，不覆盖正式文件。
2. 保留 proxies 中三个节点及其参数，仅将两个 proxy-groups 的成员都改为单个 CF-A，如下片段所示。
3. 导入并选中 test-A.yaml，重复 HTTP 204 和出口检查，记录实际使用 CF-A。
4. 另存 test-B.yaml、test-C.yaml，分别把两处成员改为 CF-B、CF-C，重复检查。
5. 完成后重新选中正式的 mate-windows.yaml，确认两组已恢复为三节点，再进入第 11 步。

~~~yaml
proxy-groups:
  - name: PROXY
    type: fallback
    url: https://www.gstatic.com/generate_204
    interval: 300
    proxies: [CF-A]
  - name: DNS-PROXY
    type: fallback
    url: https://www.gstatic.com/generate_204
    interval: 300
    proxies: [CF-A]
~~~

只改一个组而另一个组仍可走其他入口，不能证明被测入口独立承担了整条连接。一次未通过就保留为失败，换候选后重新验证，不用 DIRECT 填补测试结果。

如果公网 IP 检查站自身不可达，不能据此唯一判定代理错误；可用另一个可信检查站交叉验证。检查站是在网络上观察你的出口，不需要把结果公开给别人。

**第 11 步：开启 Windows TUN，验证接管**

前一步通过后，才在 FlClash 开启 TUN，按客户端要求允许管理员/Helper 服务权限。保持规则模式，关闭 Windows 系统代理，避免显式代理掩盖 TUN 故障。

窗口 A / Windows PowerShell：

~~~powershell
Get-NetAdapter |
    Where-Object { $_.InterfaceDescription -match 'Tunnel|TUN|Meta' -or $_.Name -match 'FlClash' } |
    Format-Table Name, ifIndex, Status, InterfaceDescription

$TunAlias = Read-Host '上面实际创建的 TUN 网卡 Name'
Get-NetIPAddress -InterfaceAlias $TunAlias -AddressFamily IPv4
Get-DnsClientServerAddress -InterfaceAlias $TunAlias -AddressFamily IPv4
curl.exe -4 --noproxy '*' --max-time 20 https://api.ipify.org
curl.exe -4 --noproxy '*' --max-time 20 -o NUL -sS -w 'HTTP=%{http_code}\n' https://www.gstatic.com/generate_204
~~~

成功标志：TUN 网卡有 IPv4 地址，内部 DNS 已配置；没有显式代理的请求仍显示预期 VPS 出口，204 测试正常。

常见 fake-ip 虚拟网段是 198.18.0.0/16，具体 TUN 地址与 DNS 由内核分配，不能把别人的网卡索引写死。本例中的 fake-ip 地址是内部映射，不是公网泄漏。

检查到某个 fake-ip 的实际路由，可先解析目标：

~~~powershell
Resolve-DnsName www.gstatic.com -Type A
# 仅在上一条得到 fake-ip 时，把下面地址改成该结果。
Find-NetRoute -RemoteIPAddress 198.18.0.10
~~~

若返回的是其他 fake-ip，请替换后再查。路由可能通过更大的聚合网段覆盖它；没找到精确 198.18.0.0/16 路由不等于没有接管。以实际选中的接口、网关及请求结果判断。

核对客户端生成的最终配置：

~~~powershell
$RuntimeConfig = Join-Path $env:APPDATA 'com.follow\clash\config.yaml'
Test-Path -LiteralPath $RuntimeConfig
Select-String -Path $RuntimeConfig -Pattern '^tun:', '^dns:', 'strict-route:', 'dns-hijack:', '#DNS-PROXY', 'interface-name:', 'route-exclude-address:' -Context 0,3
~~~

若客户端版本改变了数据目录，从应用的“打开配置目录”功能寻找最终运行文件，不改数据库凑合。成功标志：TUN 实际 enable、strict-route 为 true、DNS 上游有 #DNS-PROXY、三个入口排除及物理网卡绑定仍在。对客户端支持的运行时修改字段，落盘值不一定等于当前内核值，还应结合 GUI/运行接口与实测判断。

本模板包含 UDP/TCP 的 53 接管请求，但 FlClash 某些生成流程会统一重写 dns-hijack；必须检查最终结果，不能只看源文件。Windows 严格路由用于阻止普通多网卡 DNS 旁路，不代表接管任意加密 DNS 或所有被排除应用。[Mihomo TUN](https://wiki.metacubex.one/config/inbound/tun/#strict-route)

防自循环分三层：

- 节点绑定实际物理出口，避免核心出站又进入 TUN。
- 三个 CF 入口 /32 路由排除，避免入口连接被捕回。
- IP-CIDR DIRECT 规则是补充，不能替代核心出口/路由排除。

切换有线、无线、USB 共享网络后，重新确认网卡绑定。不要把教程中的网卡名改成虚拟 TUN。若开 TUN 后连接大量递归到自身入口、短时间出现很多超时或本地套接字冲突，先停下 TUN 排查回环，不继续高频测速。

**第 12 步：验证分流与 DNS 防泄漏**

先在客户端日志核对既定分流，不拿任意 IP 查询站的结果推断所有网站的出口：

~~~powershell
curl.exe -4 --noproxy '*' --max-time 15 -I https://www.qq.com
curl.exe -4 --noproxy '*' --max-time 20 -o NUL -sS https://www.gstatic.com/generate_204
~~~

QQ 域名应命中 DIRECT，第二项应命中 PROXY。网站自身的 403/重定向不等于规则未命中，结合连接日志判断。本文保留显式域名和局域网规则；它不是覆盖所有国内网站的完整规则库，未列出的域名会命中兜底代理。规则库扩展应在基础验收后另做。

浏览器 DNS 测试：

1. 使用本机浏览器，不使用运行在其他服务器上的远程浏览器结果代替。
2. 用独立临时配置或无扩展的新浏览器环境做基线。无痕窗口仍可能继承策略和安全 DNS，不能自动视为干净环境。
3. 记录浏览器安全 DNS 设置；为单独验证系统/TUN DNS，可临时关闭浏览器自带安全 DNS，测试后恢复原设置，并在日常设置下再测一次。
4. 打开 [DNSLeakTest](https://www.dnsleaktest.com/)，先核对网页公网出口，再点击 Standard test，等待明确显示 Test complete。
5. 预期解析器来自设置的公共 DNS 服务商，且不出现本地宽带/手机运营商解析器。DNS 所在城市与 VPS 不完全一致，单凭地理差异不能认定泄漏。
6. 不要求 Cloudflare 与 Google 必须同时出现：上游竞速、缓存和 Anycast 会影响当次可见解析器。

再做指定 DNS 的命令行对照。先从实际网卡读取 DNS，不写死别人的网关：

~~~powershell
$TunDns = @((Get-DnsClientServerAddress -InterfaceAlias $TunAlias -AddressFamily IPv4).ServerAddresses)[0]
$PhysicalDns = @((Get-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4).ServerAddresses)[0]
$TunDns
$PhysicalDns
nslookup.exe -type=txt o-o.myaddr.l.google.com $TunDns
nslookup.exe -type=txt o-o.myaddr.l.google.com $PhysicalDns
~~~

本例预期：TUN DNS 正常响应；在严格路由确实阻止该普通 DNS 旁路时，向物理网卡 DNS 发起的查询被阻止或超时。物理 DNS 不一定等于网关，不能随意替换。

这只是对照实验：超时也可能由服务器不响应造成；正常响应也可能已被重定向。要结合解析器结果、最终配置和浏览器测试，而非仅凭一次超时下结论。TXT 内容中出现解析器自己的地址或 ECS，也不等于电脑具有对应 IPv6 接口。

成功标志：网页出口正确、DNS 测试完成、未出现本地运营商解析器、TUN DNS 可用。该结论只覆盖当次环境，不代表所有应用或浏览器都已验证。HTTPS DNS 加密本身也不保证经过代理，#DNS-PROXY 的路由指定同样需要生效。[Mihomo DNS](https://wiki.metacubex.one/config/dns/)

**第 13 步：WebRTC、回退和性能的进一步验收**

WebRTC 在自己的实际浏览器上打开 [BrowserLeaks WebRTC](https://browserleaks.com/webrtc)，不必授予摄像头和麦克风权限。比较 HTTP 公网出口与 WebRTC 暴露的公网候选：若出现本地运营商公网出口，再检查浏览器和网络路径。私有地址、随机 .local 主机候选本身不是公网出口泄漏。页面报错、被拦截或测试未完成时记为“未完成”，不记为通过。

fallback 的结构能静态核对，但只有进行故障切换实验才能宣称切换通过。建议在自己另存的实验配置中，逐次移除/禁用当前优先入口并重载，再确认真实请求和出口；不要只看仍能 ping 通，不要通过任意关闭安全软件或改系统防火墙模拟故障。三个入口全部不可用时，代理连接不应自动选择 DIRECT；原有直连规则仍可使用本地网络。本文不提供自动破坏当前网络的故障注入脚本。

性能对照：

~~~powershell
curl.exe -4 --noproxy '*' --max-time 20 -o NUL -sS -w 'dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} first=%{time_starttransfer} total=%{time_total}\n' https://www.gstatic.com/generate_204

curl.exe -4 --proxy http://127.0.0.1:7890 --max-time 20 --http1.1 -sS -w 'new_connections=%{num_connects} total=%{time_total}s\n' -o NUL https://www.gstatic.com/generate_204 -o NUL https://www.gstatic.com/generate_204 -o NUL https://www.gstatic.com/generate_204
~~~

第二条在一个 curl 进程内重复请求，观察后续是否复用连接；不是三个单独 curl。timing 字段多为从请求起点累计的时间，不能把它们全部相加；fake-ip/本地代理也会使 connect 很快，不能当成到 CF 的真实 RTT。

节点测速常包含新连接、TLS、WS 和目标网站响应。若首次较慢、复用较快，不能把首次数字当成每个数据包的延迟。先比较完整节点链路与稳定性，再给 fallback 排序。缩短 interval 主要加快发现失效，不会直接降低正常线路 RTT。

统一延迟影响测速口径，不能只因显示值变低就宣称真实新连接提速；原始端点是 IP 时，TCP 并发也不会自动在三个 CF 节点间择优。[fallback](https://wiki.metacubex.one/config/proxy-groups/fallback/)、[统一延迟](https://wiki.metacubex.one/config/general/#统一延迟)

**完成验收表：由读者填写**

| 项目 | 通过标志 | 你的结果 |
|---|---|---|
| 域名 | 区域 Active，A 记录已代理，边缘证书 Active | 待填 |
| 服务端 | 实际账户配置测试通过，服务 active、443 监听 | 待填 |
| 三个入口 | 分别通过实际域名和路径的 WS 101 | 待填 |
| 完整鉴权 | 显式代理 HTTP 204，出口符合预期 | 待填 |
| TUN | 系统代理关闭，无显式代理请求仍经 VPS | 待填 |
| 最终配置 | 严格路由、DNS 组、出口绑定与 /32 排除保留 | 待填 |
| DNS | 浏览器测试完成，无本地运营商解析器 | 待填 |
| WebRTC | 实际浏览器已完成公网候选对照 | 待填 |
| Android | Wi-Fi/移动数据分别验证 | 待填 |
| 故障回退 | 单入口/全入口故障策略经实际实验验证 | 待填 |
| IPv6 | 本教程未覆盖，不自行勾选通过 | 未覆盖 |


**附录 A：Android Clash Meta**

1. 从 [Clash Meta for Android 官方发布页](https://github.com/MetaCubeX/ClashMetaForAndroid/releases) 获取适合设备架构的客户端；不是任意名称含 Clash 的旧客户端都支持本模板语法。
2. 将 generated/mate-android.yaml 私下传到手机。在客户端从文件导入，选中该配置，启动并授予 Android VPN 权限。
3. 采用规则模式，检查应用访问控制没有把需要验证的浏览器排除在 VPN 外。
4. Android 版保留三入口、两个 fallback、DNS、路径与分流，但去掉三个 Windows 网卡绑定。不把 Wi-Fi/WLAN/以太网等电脑名称填到手机节点。
5. VPN/TUN 的创建由 Android 客户端管理，不机械照搬 Windows 的设备名、网卡索引或 Helper 设置。
6. 若“代理”页面空白，日志却已显示 PROXY/DNS-PROXY，检查代理页菜单 → 过滤 → 不可选择是否勾选；取消后查看自动回退组。fallback 并非可手动选择节点的 Selector 组，显示过滤不代表组未加载。[客户端菜单源码](https://github.com/MetaCubeX/ClashMetaForAndroid/blob/main/design/src/main/res/menu/menu_proxy.xml)
7. 记录系统“私人 DNS”和浏览器安全 DNS 设置。基线测试时可暂时关闭指定的私人 DNS/浏览器 DoH，再在恢复日常设置后复测；这些设置可能改变解析路径，不能仅因电脑通过就认定手机通过。
8. 分别在 Wi-Fi 与移动数据下完成出口、DNS 和浏览器测试。测试真实配置，不把电脑的独立浏览器结果当成手机结果。

成功标志：配置加载、实际网页请求正常、出口符合预期、DNS 未出现本地运营商解析器。无法完成的项目保留“未验证”，不写成通过。本教程不要求 root 手机，也不在手机上扫描大批入口。

**附录 B：SSH 不通时，用商家 VNC 排查**

VNC/网页控制台通常不依赖用户到 VPS SSH 端口的路径。先从商家后台确认机器和公网地址仍属于自己，再打开控制台登录。不要连接已经回收给他人的旧地址。

在 VPS 控制台执行：

~~~bash
ip -br address
ip route
systemctl status ssh --no-pager
ss -ltnp
ufw status numbered
journalctl -u ssh -n 40 --no-pager
/usr/sbin/sshd -t
~~~

判断：

- ssh 服务未运行：检查配置后再启动。
- 监听端口不是商家资料中的端口：按真实监听端口测试，不假设一定为 22。
- UFW 没有放行真实 SSH 端口：只增加该端口规则，不清空整套防火墙。
- 服务监听、防火墙正常，但本地不通：对照另一独立网络及商家控制台，不能仅凭 ping 唯一断定封锁。
- VPS 自己没有正常地址/默认路由：先向商家处理网络交付问题。
- 普通 Cloudflare 橙云的 WebSocket 代理不等于 SSH 代理，不能用开启橙云自动修复 SSH。

只有上面的检查确认需要时，才做对应操作。例如实际 SSH 端口确为 22：

~~~bash
SSH_PORT=22
ufw allow "$SSH_PORT/tcp" comment 'SSH-admin'
/usr/sbin/sshd -t && systemctl enable --now ssh
~~~

成功标志：ss 能看到实际端口监听，并从电脑新建 SSH 成功。不要在尚未建立密钥登录的情况下关闭密码登录，也不为了套教程修改商家原有认证方式。

若必须在 VNC 内继续安装：

- 私钥仍按第 6 步在 VPS 生成，不复制长私钥。
- CSR 是公有请求，复制到 Cloudflare 时须完整；Cloudflare 不能解析就重新核对，不能删改内容凑合。
- 优先恢复 SSH/SCP。若 VNC 无法可靠导出 CSR 或粘贴文本，这是控制台传输能力的限制，先解决该限制，不把私钥发到公共网站或 DNS TXT。
- 公有证书、仍带占位符的公开模板可采用下面的分块编码方法；它不用于传播私钥。

窗口 A / Windows PowerShell，以公有证书为例：

~~~powershell
$InputFile = Resolve-Path .\origin.pem
$Encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($InputFile))
for ($i = 0; $i -lt $Encoded.Length; $i += 160) {
    $Length = [Math]::Min(160, $Encoded.Length - $i)
    '{0:D3}: {1}' -f ($i / 160), $Encoded.Substring($i, $Length)
}
Get-FileHash -LiteralPath $InputFile -Algorithm SHA256
~~~

VPS 控制台先确认 Caps Lock 与输入法状态，输入短命令检查大小写。创建一个全新的暂存文件：

~~~bash
test ! -e /root/origin-transfer.b64 || { echo "暂存文件已存在，请另选名称"; exit 1; }
umask 077
touch /root/origin-transfer.b64
~~~

依次输入下面这种短命令，把每段真实 Base64 放入单引号；不要输入左侧序号。每段只执行一次、顺序不变，段间不加换行：

~~~bash
printf '%s' '粘贴第000段的真实Base64内容' >> /root/origin-transfer.b64
printf '%s' '粘贴第001段的真实Base64内容' >> /root/origin-transfer.b64
~~~

示例中文不是 Base64 数据，必须替换。完成所有段后：

~~~bash
base64 -d /root/origin-transfer.b64 > /root/origin-transfer.pem
sha256sum /root/origin-transfer.pem
openssl x509 -in /root/origin-transfer.pem -noout -subject -dates
~~~

成功标志：摘要与本机原文件相同、证书可解析。摘要不一致就停下重传，不安装损坏文件。通过后：

~~~bash
install -o root -g xray -m 640 /root/origin-transfer.pem /usr/local/etc/xray/cert/origin.pem
~~~

再做第 6 步的域名、公钥匹配与账户读取检查。公开的模板 JSON 也可用同样方法编码，校验后保存为 /root/xray-server.template.json，再用第 7 步在 VPS 本地填入 UUID/路径；不要把已经含凭据的配置放到公共传输服务。

**附录 C：基础验收后，只允许 Cloudflare 回源 443**

这属于进阶加固。先完成正常源站与代理请求验收，再限制访问，否则会把“应用未搭好”和“防火墙拦截”混在一起。商家的管理口和 SSH 规则保持独立，不删除 SSH 放行。本附录针对 UFW，不能与其他不明防火墙管理器混用。

目的：让源站 443 不直接接受任意公网来源连接。它不能证明源站地址永远不会暴露；仅按 CF 来源范围放行，也不等于只有自己的 CF 站点能回源。更强的回源身份认证需单独设计。

窗口 B / VPS Bash，先下载官方完整的 IPv4 和 IPv6 范围：

~~~bash
install -d -m 700 /root/cf-origin-ranges
curl -fL --max-time 30 https://www.cloudflare.com/ips-v4 -o /root/cf-origin-ranges/ips-v4.txt
curl -fL --max-time 30 https://www.cloudflare.com/ips-v6 -o /root/cf-origin-ranges/ips-v6.txt
python3 - <<'PY'
from pathlib import Path
import ipaddress
base = Path("/root/cf-origin-ranges")
all_ranges = []
for name, version in [("ips-v4.txt", 4), ("ips-v6.txt", 6)]:
    rows = (base / name).read_text().splitlines()
    rows = [r.strip() for r in rows if r.strip()]
    if not rows:
        raise SystemExit("地址列表为空")
    for row in rows:
        net = ipaddress.ip_network(row, strict=True)
        if net.version != version or net.prefixlen == 0 or not net.is_global:
            raise SystemExit("地址列表内容异常")
        all_ranges.append(str(net))
(base / "validated.txt").write_text("\n".join(all_ranges) + "\n")
print("范围校验完成，共", len(all_ranges), "段")
PY
~~~

成功标志：两份下载成功，Python 解析全部 CIDR，而不是 HTML 错误页，输出非零数量。不使用某个示例地区的子集；所有可能回源的 CF 地址都需要覆盖。[官方地址范围](https://www.cloudflare.com/ips/)

先添加 CF 范围允许规则：

~~~bash
(
  set -eu
  while IFS= read -r cidr; do
    ufw allow proto tcp from "$cidr" to any port 443 comment 'Cloudflare-origin'
  done < /root/cf-origin-ranges/validated.txt
)
ufw status numbered
~~~

如果 UFW 自身关闭了 IPv6，IPv6 规则可能不会生效；需结合主机实际网络和商家安全组确认，不把这段操作当成 IPv6 泄漏测试。

确认没有添加失败、CF 范围已允许、SSH 放行仍在后，才删除主线第 4 步添加的全网 443 放行：

~~~bash
ufw delete allow 443/tcp
ufw status verbose
~~~

只删除该明确的全网规则，不按不明编号批量删除，不 ufw reset。若还有其他形式的全网 443 放行，应先识别来源，再单独处理；不能因为看见一条删除成功就认定全部限制完成。

成功验收：

1. 从电脑通过三个 CF 入口重新做 WS 101 和真实代理 204，仍应成功。
2. 从普通非 CF 的外部网络直连源站 443 应被拒绝/超时；这仅作源站访问限制测试，不在公开日志中透露地址。
3. SSH 新连接仍正常。
4. 若失败但此前通过，先检查是否漏了 CF 范围，不随意关闭所有防火墙。

CF 范围会更新。维护时重新下载并验证，先添加新增范围、验证回源，再删除确认过期的旧范围；不要先清空当前可用规则。商家安全组若同时限制来源，也必须同步维护。

**附录 D：常见故障与排查顺序**

| 现象 | 优先检查 | 不足以支持的结论 |
|---|---|---|
| SSH 超时 | 机器归属、实际端口、监听、安全组、UFW、独立网络 | ping 通不表示 SSH 正常，超时也不唯一等于被封 |
| Xray 启动失败 | run -test、实际服务账户、证书/私钥、目录权限、443 占用 | root 能读取不代表服务账户能读取 |
| 101 正常但节点不通 | UUID、路径、真实 VLESS 请求、源站出网及日志 | WS 成功不等于鉴权成功 |
| 系统代理可用，TUN 不通 | 实际配置、权限、地址/路由、物理出口和端点排除 | 不能先认定所有版本 TUN 都有不可修复缺陷 |
| 开 TUN 后大量入口递归连接 | 防回环、重复运行的客户端、错误网卡绑定 | 不应持续高频测速放大问题 |
| 关闭 TUN 后短时仍不通 | 残留路由/代理状态、连接堆积、客户端日志 | 不因此直接关闭安全软件或重置全网 |
| 网页出口对，DNS 仍有本地运营商 | 最终 DNS、严格路由、浏览器 DoH、应用绕过 | 网页出口不是 DNS 验收 |
| 自动组没显示 | 当前加载配置、显示过滤、是否只有 fallback | UI 不显示不代表内核没加载 |
| 三个节点都显示高延迟 | 冷连接、连接复用、CF 接入、回源和目标网站 | 节点数字不是 ICMP ping，也不唯一是 TUN 性能 |
| 换网络后失效 | 物理网卡名称、接口地址、实际路由及候选入口 | 同一份绑定不保证适配所有网络 |

每次修改只针对一个已定位问题。先保存自己的可用配置，再改变参数、重新加载、复测；不要同时换内核、协议、DNS、路由和服务器，导致不知道哪项起作用。原始日志和配置保留供自己核对，公开讨论先脱敏。

**附录 E：维护、案例与验证边界**

日常只读检查：

~~~bash
systemctl is-active xray
ss -ltnp '( sport = :443 )'
journalctl -u xray -n 40 --no-pager
openssl x509 -in /usr/local/etc/xray/cert/origin.pem -noout -dates
~~~

客户端换 CF 入口时，同步节点 server、/32 排除和端点规则；域名、UUID、WS 路径只有在确实变更时才同步修改。服务器迁移时，先验证新源站与证书，再切 DNS，不能仅凭旧配置“看起来一样”就下线旧服务。

证书、鉴权资料和 SSH 资料不要进入公开截图、TXT 记录、工单附件或文章仓库。本文展示公共 DNS 地址、回环/局域网与 fake-ip 范围，它们不是作者身份信息。分享前也检查生成文件、浏览器公网出口、ECS、服务日志、文件名和主机名。

已有环境的脱敏案例观测：

| 项目 | 当时观察 |
|---|---|
| Windows TUN | 成功取得虚拟地址，无系统代理也能联网 |
| DNS 修复前 | 浏览器测试出现本地运营商解析器 |
| DNS 修复后 | 标准测试的 6 个解析器均属于 Cloudflare，未再出现本地运营商解析器 |
| 指定 DNS 对照 | TUN DNS 正常；物理网卡 DNS 查询由响应变为超时 |
| 显式代理新 HTTPS 请求 | 约 1.41–1.51 秒 |
| TUN 新 HTTPS 请求 | 约 1.44–1.53 秒 |
| 同一连接后续请求 | 约 275–281 ms |

这些是此前环境的观测，既不是所有网络的性能承诺，也不表示教程的全部新默认值已在全新 VPS 上实装验收。教程模板改为不保留 DIRECT，并采用固定版本与本地 CSR 流程；不要把旧实机数据冒充新模板的完整端到端测试。

编写时另在独立目录用虚构参数测试了配置生成脚本，并对服务端候选配置执行 Xray v26.11.9 的 run -test，返回 Configuration OK。离线检查使用临时自签证书，只验证配置可解析，不验证 CF 回源信任，也不验证 Debian 权限、防火墙或公网路线。本教程没有操作作者现有 VPS、网络设置或运行配置。


**附录 F：完整配置模板与本地生成脚本**

随包已有以下文件；仅获得本文的读者，也可按标题给出的相对路径建立同名文件，再从第 1 步开始。JSON/YAML 保存 UTF-8；generate-config.ps1 建议保存为 UTF-8 with BOM，以兼容 Windows PowerShell 5.1 的中文字符串。文件夹 templates 需自行创建。

原始模板不可直接导入：JSON 的 UUID、路径和 YAML 的所有双下划线占位符都要由脚本填好。脚本不会联网验证候选 IP，也不会把配置自动加载到客户端。

**templates/xray-server.json**

~~~json
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "inbounds": [
    {
      "tag": "vless-ws-tls",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "__UUID__"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "alpn": [
            "http/1.1"
          ],
          "certificates": [
            {
              "certificateFile": "/usr/local/etc/xray/cert/origin.pem",
              "keyFile": "/usr/local/etc/xray/cert/origin.key"
            }
          ]
        },
        "wsSettings": {
          "path": "__WS_PATH__"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
~~~

**templates/mate-windows.yaml**

~~~yaml
# 原始模板含占位符，不能直接导入；请导入 generated 目录的已填参文件。
# PROXY 与 DNS-PROXY 都不含 DIRECT；三入口不可用时不自动回退到本地直连。
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false

dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - dns.msftnsci.com
    - www.msftnsci.com
    - www.msftconnecttest.com
  respect-rules: false
  default-nameserver:
    - "https://1.1.1.1/dns-query#DNS-PROXY"
    - "https://8.8.8.8/dns-query#DNS-PROXY"
  nameserver:
    - "https://1.1.1.1/dns-query#DNS-PROXY"
    - "https://8.8.8.8/dns-query#DNS-PROXY"

tun:
  auto-route: true
  auto-detect-interface: true
  strict-route: true
  dns-hijack:
    - any:53
    - tcp://any:53
  route-exclude-address:
    - __EDGE_A__/32
    - __EDGE_B__/32
    - __EDGE_C__/32

proxies:
  - name: CF-A
    type: vless
    server: __EDGE_A__
    interface-name: __INTERFACE_YAML__
    port: 443
    uuid: __UUID__
    udp: true
    tls: true
    skip-cert-verify: false
    servername: __DOMAIN__
    alpn:
      - http/1.1
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: __WS_PATH__
      headers:
        Host: __DOMAIN__

  - name: CF-B
    type: vless
    server: __EDGE_B__
    interface-name: __INTERFACE_YAML__
    port: 443
    uuid: __UUID__
    udp: true
    tls: true
    skip-cert-verify: false
    servername: __DOMAIN__
    alpn:
      - http/1.1
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: __WS_PATH__
      headers:
        Host: __DOMAIN__

  - name: CF-C
    type: vless
    server: __EDGE_C__
    interface-name: __INTERFACE_YAML__
    port: 443
    uuid: __UUID__
    udp: true
    tls: true
    skip-cert-verify: false
    servername: __DOMAIN__
    alpn:
      - http/1.1
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: __WS_PATH__
      headers:
        Host: __DOMAIN__

proxy-groups:
  - name: PROXY
    type: fallback
    url: https://www.gstatic.com/generate_204
    interval: 300
    proxies:
      - CF-A
      - CF-B
      - CF-C

  - name: DNS-PROXY
    type: fallback
    url: https://www.gstatic.com/generate_204
    interval: 300
    proxies:
      - CF-A
      - CF-B
      - CF-C

rules:
  - IP-CIDR,__EDGE_A__/32,DIRECT,no-resolve
  - IP-CIDR,__EDGE_B__/32,DIRECT,no-resolve
  - IP-CIDR,__EDGE_C__/32,DIRECT,no-resolve
  - DOMAIN-SUFFIX,__DOMAIN__,DIRECT
  - DOMAIN-SUFFIX,bilibili.com,DIRECT
  - DOMAIN-SUFFIX,bilivideo.com,DIRECT
  - DOMAIN-SUFFIX,hdslb.com,DIRECT
  - DOMAIN-SUFFIX,qq.com,DIRECT
  - DOMAIN-SUFFIX,taobao.com,DIRECT
  - DOMAIN-SUFFIX,aliyun.com,DIRECT
  - DOMAIN-SUFFIX,jd.com,DIRECT
  - DOMAIN-SUFFIX,baidu.com,DIRECT
  - DOMAIN-SUFFIX,163.com,DIRECT
  - DOMAIN-SUFFIX,zhihu.com,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - MATCH,PROXY
~~~

**templates/mate-android.yaml**

~~~yaml
# 原始模板含占位符，不能直接导入；请导入 generated 目录的已填参文件。
# PROXY 与 DNS-PROXY 都不含 DIRECT；三入口不可用时不自动回退到本地直连。
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false

dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - dns.msftnsci.com
    - www.msftnsci.com
    - www.msftconnecttest.com
  respect-rules: false
  default-nameserver:
    - "https://1.1.1.1/dns-query#DNS-PROXY"
    - "https://8.8.8.8/dns-query#DNS-PROXY"
  nameserver:
    - "https://1.1.1.1/dns-query#DNS-PROXY"
    - "https://8.8.8.8/dns-query#DNS-PROXY"

tun:
  auto-route: true
  auto-detect-interface: true
  strict-route: true
  dns-hijack:
    - any:53
    - tcp://any:53
  route-exclude-address:
    - __EDGE_A__/32
    - __EDGE_B__/32
    - __EDGE_C__/32

proxies:
  - name: CF-A
    type: vless
    server: __EDGE_A__
    port: 443
    uuid: __UUID__
    udp: true
    tls: true
    skip-cert-verify: false
    servername: __DOMAIN__
    alpn:
      - http/1.1
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: __WS_PATH__
      headers:
        Host: __DOMAIN__

  - name: CF-B
    type: vless
    server: __EDGE_B__
    port: 443
    uuid: __UUID__
    udp: true
    tls: true
    skip-cert-verify: false
    servername: __DOMAIN__
    alpn:
      - http/1.1
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: __WS_PATH__
      headers:
        Host: __DOMAIN__

  - name: CF-C
    type: vless
    server: __EDGE_C__
    port: 443
    uuid: __UUID__
    udp: true
    tls: true
    skip-cert-verify: false
    servername: __DOMAIN__
    alpn:
      - http/1.1
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: __WS_PATH__
      headers:
        Host: __DOMAIN__

proxy-groups:
  - name: PROXY
    type: fallback
    url: https://www.gstatic.com/generate_204
    interval: 300
    proxies:
      - CF-A
      - CF-B
      - CF-C

  - name: DNS-PROXY
    type: fallback
    url: https://www.gstatic.com/generate_204
    interval: 300
    proxies:
      - CF-A
      - CF-B
      - CF-C

rules:
  - IP-CIDR,__EDGE_A__/32,DIRECT,no-resolve
  - IP-CIDR,__EDGE_B__/32,DIRECT,no-resolve
  - IP-CIDR,__EDGE_C__/32,DIRECT,no-resolve
  - DOMAIN-SUFFIX,__DOMAIN__,DIRECT
  - DOMAIN-SUFFIX,bilibili.com,DIRECT
  - DOMAIN-SUFFIX,bilivideo.com,DIRECT
  - DOMAIN-SUFFIX,hdslb.com,DIRECT
  - DOMAIN-SUFFIX,qq.com,DIRECT
  - DOMAIN-SUFFIX,taobao.com,DIRECT
  - DOMAIN-SUFFIX,aliyun.com,DIRECT
  - DOMAIN-SUFFIX,jd.com,DIRECT
  - DOMAIN-SUFFIX,baidu.com,DIRECT
  - DOMAIN-SUFFIX,163.com,DIRECT
  - DOMAIN-SUFFIX,zhihu.com,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - MATCH,PROXY
~~~

**generate-config.ps1**

~~~powershell
[CmdletBinding()]
param(
    [string]$Domain,
    [string]$Uuid,
    [string]$WsPath,
    [string]$EdgeA,
    [string]$EdgeB,
    [string]$EdgeC,
    [string]$InterfaceAlias,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'generated')
)
$ErrorActionPreference = 'Stop'
foreach ($field in @('Domain','Uuid','WsPath','EdgeA','EdgeB','EdgeC','InterfaceAlias')) {
    if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $field -ValueOnly))) {
        Set-Variable -Name $field -Value (Read-Host "请输入 $field（含义见 README 参数表）")
    }
}
$Domain = $Domain.Trim().ToLowerInvariant()
$Uuid = $Uuid.Trim()
$WsPath = $WsPath.Trim()
$InterfaceAlias = $InterfaceAlias.Trim()
if ($Domain.Length -gt 253 -or $Domain -notmatch '^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$') {
    throw 'Domain 必须是域名，不含 https://、端口或路径。'
}
$parsedUuid = [guid]::Empty
if (-not [guid]::TryParse($Uuid, [ref]$parsedUuid)) { throw 'Uuid 不是有效 UUID。' }
$Uuid = $parsedUuid.ToString()
if ($WsPath -notmatch '^/[A-Za-z0-9_-]+$') { throw 'WsPath 应以 / 开头，后面只使用字母、数字、下划线或短横线。' }
$edges = @($EdgeA.Trim(), $EdgeB.Trim(), $EdgeC.Trim())
foreach ($edge in $edges) {
    $parsedIp = $null
    if (-not [Net.IPAddress]::TryParse($edge, [ref]$parsedIp) -or
        $parsedIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $parsedIp.ToString() -ne $edge) {
        throw "入口必须是标准 IPv4 地址：$edge"
    }
}
if (($edges | Select-Object -Unique).Count -ne 3) { throw '三个入口必须互不相同。' }
if ([string]::IsNullOrWhiteSpace($InterfaceAlias) -or $InterfaceAlias.Contains([string][char]13) -or $InterfaceAlias.Contains([string][char]10)) { throw '网卡名不能为空或包含换行。' }
if (Test-Path -LiteralPath $OutputDirectory) { throw '输出目录已存在，请另选 -OutputDirectory；本脚本不覆盖已有文件。' }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$replacements = [ordered]@{
    '__DOMAIN__' = $Domain
    '__UUID__' = $Uuid
    '__WS_PATH__' = $WsPath
    '__EDGE_A__' = $edges[0]
    '__EDGE_B__' = $edges[1]
    '__EDGE_C__' = $edges[2]
    '__INTERFACE_YAML__' = ("'" + $InterfaceAlias.Replace("'", "''") + "'")
}
$server = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'templates\xray-server.json'), $utf8)
$windows = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'templates\mate-windows.yaml'), $utf8)
$android = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'templates\mate-android.yaml'), $utf8)
foreach ($entry in $replacements.GetEnumerator()) {
    $server = $server.Replace($entry.Key, $entry.Value)
    $windows = $windows.Replace($entry.Key, $entry.Value)
    $android = $android.Replace($entry.Key, $entry.Value)
}
foreach ($document in @($server, $windows, $android)) {
    if ($document -match '__[A-Z_]+__') { throw '存在未替换的占位符。' }
}
$null = $server | ConvertFrom-Json
$null = New-Item -ItemType Directory -Path $OutputDirectory
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'xray-server.json'), $server, $utf8)
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'mate-windows.yaml'), $windows, $utf8)
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'mate-android.yaml'), $android, $utf8)
Write-Host "生成完成：$OutputDirectory"
Write-Host '仅写入新目录；没有修改客户端设置、服务器、网络或防火墙。'
Write-Host '生成后的配置包含你自己的鉴权信息，请保管，不要公开分享 generated 目录。'
~~~

**资料来源与版本边界**

- [Xray 官方安装器及固定提交](https://github.com/XTLS/Xray-install/tree/9d3ad49a3294d4c1d042f1fb6a16360b4d1befd1)
- [Xray v26.11.9 发行说明](https://github.com/XTLS/Xray-core/releases/tag/v26.11.9)
- [Xray WebSocket](https://xtls.github.io/config/transports/websocket.html)
- [Xray 路由](https://xtls.github.io/config/routing.html)
- [Cloudflare WebSockets](https://developers.cloudflare.com/network/websockets/)
- [Cloudflare Full (strict)](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)
- [Cloudflare Origin CA 与 CSR](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)
- [Cloudflare 官方 IP 范围](https://www.cloudflare.com/ips/)
- [CloudflareSpeedTest 官方说明](https://github.com/XIU2/CloudflareSpeedTest)
- [Mihomo DNS](https://wiki.metacubex.one/config/dns/)
- [Mihomo TUN](https://wiki.metacubex.one/config/inbound/tun/)
- [Mihomo fallback](https://wiki.metacubex.one/config/proxy-groups/fallback/)
- [FlClash v0.9.3](https://github.com/chen08209/FlClash/releases/tag/v0.9.3)
- [Clash Meta Android](https://github.com/MetaCubeX/ClashMetaForAndroid/releases)

资料核对日期为本文版本日期。官方文档、控制台界面、客户端和网络会变化；每次更换版本重新检查，不把固定教程当永久兼容承诺。
