
# WordPress-modsec2.3
## 项目简介
WordPress-modsec2.3 是专门为搭载 ModSecurity 2.3 版本的服务器环境适配 WordPress 程序的安全优化项目。该项目聚焦于解决 WordPress 与 ModSecurity 2.3 之间的兼容性问题，同时针对性强化 WordPress 站点在该安全模块下的防护能力，能够有效拦截针对 WordPress 的常见攻击（如SQL注入、XSS跨站脚本、恶意请求伪造等），降低站点被入侵、篡改的风险，保障基于 WordPress 搭建的网站在启用 ModSecurity 2.3 时的稳定运行与安全防护。

本项目适配 WordPress 主流版本，规则与配置均贴合 ModSecurity 2.3 的特性，避免因安全规则过度严格导致的正常功能异常，也弥补了默认规则对 WordPress 场景覆盖不足的问题。

## 部署指南
### 前提条件
1. 服务器已安装 ModSecurity 2.3 版本；
2. 服务器已部署 WordPress 程序；
3. 本地/服务器环境已安装 Git 工具；
4. 拥有服务器管理员权限（可执行 `sudo` 命令）。

### 克隆项目
通过 Git 克隆本项目到服务器指定目录（推荐存放至 ModSecurity 规则目录，或自定义规则目录），执行以下命令：
```bash
git clone https://github.com/chrispengcn/wordpress-modsec2.3.git
```

### 配置文件权限并运行脚本
1. 进入克隆后的项目目录：
```bash
cd wordpress-modsec2.3
```
2. 设置文件执行权限（确保脚本可正常运行）：
```bash
chmod +x run-modsec-wp.sh
```
3. 执行部署脚本（需管理员权限）：
```bash
sudo sh run-modsec-wp.sh
```

脚本运行完成后，ModSecurity 2.3 针对 WordPress 的安全规则将自动生效，无需额外手动集成规则文件。

## 注意事项
1. 部署前建议备份当前 ModSecurity 已有规则配置，避免配置冲突；
2. 执行脚本前请确保服务器已满足「前提条件」，否则可能导致脚本运行失败；
3. 若启用后出现 WordPress 功能异常（如后台操作失败、表单提交报错），可结合 ModSecurity 日志排查并微调规则，适配自身业务场景；
4. 运行脚本时需输入管理员密码（sudo 验证），请确保当前操作账户具备 sudo 权限。

## 免责声明
本项目仅作为 WordPress 与 ModSecurity 2.3 适配的安全优化参考，使用者需根据自身站点的实际情况测试、调整规则。项目作者不对因使用本项目规则导致的站点故障、数据损失等问题承担责任。

### 总结
1. 项目核心作用是适配 ModSecurity 2.3 与 WordPress，强化 WordPress 站点的安全防护并解决兼容性问题；
2. 部署核心步骤为：git 克隆项目 → 进入目录设置脚本权限 → 以 sudo 权限运行部署脚本；
3. 部署前需确认服务器满足 ModSecurity 2.3 已安装、有 sudo 权限等前提条件，建议备份原有规则。
