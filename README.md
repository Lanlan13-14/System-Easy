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
### 特别感谢
[byJoey](https://github.com/byJoey/Actions-bbr-v3)
>
[qichiyu](https://github.com/qichiyuhub/autoshell)
