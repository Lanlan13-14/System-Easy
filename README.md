# System-Easy
#### 快速管理Debian/Ubuntu系统
### 1. 安装
```
curl -L https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/system.sh -o /tmp/system-easy && chmod +x /tmp/system-easy && sudo mv /tmp/system-easy /usr/local/bin/system-easy && system-easy
```
### 2. 已安装？执行
```
sudo system-easy
```
### 3. 卸载
##### 卸载选项在脚本中已提供
#### 4.GitHub加速的配置文件位于：

```
/etc/system-easy/proxy.conf
```
#### 仅bbr优化
```
bash <(curl -fsSL https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/bbr.sh)
```
#### 卸载bbr优化
```
bash <(curl -fsSL https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/remove-bbr-tuning.sh)
```
#### 仅DDNS脚本
```
curl -fsSL https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/ddns.sh -o /tmp/ddns-easy && chmod +x /tmp/ddns-easy && sudo mv /tmp/ddns-easy /usr/local/bin/ddns-easy && ddns-easy
```
#### 卸载DDNS脚本
##### 卸载选项在脚本中已提供
#### 仅TCPING（Debian/Ubuntu）
```
sudo apt update && sudo apt install -y bc tcptraceroute && sudo wget -O /usr/bin/tcping https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/tcping.sh && sudo chmod +x /usr/bin/tcping
```
#### 卸载TCPING（Debian/Ubuntu）
```
sudo rm -f /usr/bin/tcping /usr/bin/tcping.sh && sudo apt remove -y bc tcptraceroute
```
#### 仅TCPING（Red Hat 系）

```bash
# RHEL/CentOS 7/8/9 及衍生版本
sudo yum install -y epel-release && sudo yum install -y bc tcptraceroute && sudo curl -o /usr/bin/tcping https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/tcping.sh && sudo chmod +x /usr/bin/tcping
```

###### 或者使用 dnf（RHEL 8+ / Fedora）：

```bash
# RHEL 8/9, Rocky Linux, AlmaLinux, Fedora
sudo dnf install -y epel-release && sudo dnf install -y bc tcptraceroute && sudo curl -o /usr/bin/tcping https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/tcping.sh && sudo chmod +x /usr/bin/tcping
```

#### 卸载TCPING（Red Hat 系）

```bash
# RHEL/CentOS 7/8/9 及衍生版本
sudo rm -f /usr/bin/tcping && sudo yum remove -y bc tcptraceroute
```

###### 使用 dnf 卸载：

```bash
# RHEL 8/9, Rocky Linux, AlmaLinux, Fedora
sudo rm -f /usr/bin/tcping && sudo dnf remove -y bc tcptraceroute
```
#### 安装Kuma-ping
```
sudo wget -O /usr/local/bin/kuma_multi_push.sh https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/kuma_multi_push.sh && sudo chmod +x /usr/local/bin/kuma_multi_push.sh && sudo ln -sf /usr/local/bin/kuma_multi_push.sh /usr/local/bin/kuma-ping && kuma-ping
```
#### 卸载Kuma-ping
```
sudo systemctl stop kuma-push.service 2>/dev/null; sudo systemctl disable kuma-push.service 2>/dev/null; sudo rm -f /etc/systemd/system/kuma-push.service; sudo rm -f /usr/local/bin/kuma-ping /usr/local/bin/kuma_multi_push.sh; sudo rm -rf /usr/local/etc/kuma_tasks.conf /var/lib/kuma-push /var/log/kuma-push.log /var/log/kuma-push.errors.log /var/log/kuma-push.debug.log; sudo systemctl daemon-reload; echo "卸载完成！"
```
#### 安装Node_exporter
```
curl -sSL -o node_exporter_install.sh https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/node_exporter_install.sh && sudo bash node_exporter_install.sh
```
#### 卸载Node_exporter
```
curl -sSL -o node_exporter_uninstall.sh https://raw.githubusercontent.com/Lanlan13-14/System-Easy/refs/heads/main/node_exporter_uninstall.sh && sudo bash node_exporter_uninstall.sh
```

### 特别感谢
[byJoey](https://github.com/byJoey/Actions-bbr-v3)
>
[qichiyu](https://github.com/qichiyuhub/autoshell)
