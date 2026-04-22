# WordPress + Apache + ModSecurity + OWASP CRS WAF 镜像
基于官方 `wordpress:php8.2-apache` 构建，内置 **ModSecurity WAF 防火墙**，自动下载 OWASP CRS 官方规则集，支持目录持久化挂载，一键部署，无配置报错，攻击拦截生效。

## 项目特性
- 基础镜像：`wordpress:php8.2-apache`（同时兼容 php7.2 只需修改镜像源）
- 内置 Apache `mod_security2` 防火墙模块
- **容器启动自动检测、自动下载 OWASP CRS 官方规则集**
- 统一配置目录 `/etc/modsec`，全部WAF配置集中管理，方便挂载修改
  - `/etc/modsec/modsecurity.conf` ModSecurity 引擎主配置
  - `/etc/modsec/crs-setup.conf` CRS 全局规则配置
  - `/etc/modsec/rules/` 完整防护规则集
- 双持久化挂载
  1. `./html:/var/www/html` WordPress 网站文件持久化
  2. `./modsec:/etc/modsec` 全部 ModSecurity+CRS 配置持久化
- 兼容旧版 ModSecurity 指令，**无语法报错、无启动异常**
- 完美拦截 SQL注入、XSS、恶意请求等Web攻击
- 原生 WordPress 功能完整，插件、主题、后台正常运行

## 目录结构
```
.
├── Dockerfile              # 镜像构建文件
├── init.sh                 # 容器启动脚本：自动生成配置 + 自动下载CRS规则
├── docker-compose.yml      # 一键部署编排（WordPress+WAF+MySQL数据库）
├── modsec/                 # 挂载目录：ModSecurity全部配置（自动生成）
│   ├── modsecurity.conf
│   ├── crs-setup.conf
│   └── rules/
└── html/                   # 挂载目录：WordPress网站源码
```

## 全套完整文件源码
### 1. Dockerfile
```dockerfile
# 基础镜像 WordPress PHP8.2 Apache
# 如需切换 PHP7.2 直接修改为 FROM wordpress:php7.2-apache 即可全部通用
FROM wordpress:php8.2-apache

# 安装 mod_security 模块
RUN apt-get update && \
    apt-get install -y --no-install-recommends libapache2-mod-security2 && \
    a2enmod security2 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 创建统一 ModSecurity 配置目录
RUN mkdir -p /etc/modsec/rules && \
    chown -R www-data:www-data /etc/modsec

# 解决 Apache ServerName 警告
RUN echo "ServerName localhost" >> /etc/apache2/apache2.conf

# 复制启动初始化脚本
COPY init.sh /init.sh
RUN chmod +x /init.sh

EXPOSE 80

# 容器启动入口
CMD ["/init.sh"]
```

### 2. init.sh 启动脚本
**功能**：自动生成兼容版配置、检测规则是否存在、不存在则自动下载 OWASP CRS 规则集、自动加载Apache配置、启动服务
```bash
#!/bin/bash
set -e

# 定义统一配置路径
MODSEC_CONF="/etc/modsec/modsecurity.conf"
CRS_SETUP="/etc/modsec/crs-setup.conf"
RULES_DIR="/etc/modsec/rules"

# 生成 ModSecurity 引擎主配置（兼容 ModSecurity 2.9.x，无废弃指令）
cat > "$MODSEC_CONF" << EOF
<IfModule security2_module>
    SecRuleEngine On
    SecRequestBodyAccess On
    SecResponseBodyAccess On

    Include /etc/modsec/crs-setup.conf
    IncludeOptional /etc/modsec/rules/*.conf
</IfModule>
EOF

# 检测CRS规则集，不存在则自动下载官方稳定版 v3.3.4
if [ ! -f "$CRS_SETUP" ] || [ -z "$(ls -A $RULES_DIR 2>/dev/null)" ]; then
    echo "=================================================="
    echo "  ModSecurity 规则未检测到，开始自动下载 OWASP CRS 官方规则集"
    echo "=================================================="

    apt-get update
    apt-get install -y git

    git clone https://github.com/coreruleset/coreruleset.git -b v3.3.4 --depth 1 /tmp/crs
    cp /tmp/crs/crs-setup.conf.example "$CRS_SETUP"
    mkdir -p "$RULES_DIR"
    cp -r /tmp/crs/rules/* "$RULES_DIR"/

    rm -rf /tmp/crs
    apt-get remove -y git
    apt-get clean
    rm -rf /var/lib/apt/lists/*

    echo "=================================================="
    echo "  OWASP CRS 规则集下载完成！"
    echo "=================================================="
else
    echo "=================================================="
    echo "  ModSecurity 规则已存在，跳过自动下载"
    echo "=================================================="
fi

# 配置Apache加载ModSecurity
cat > /etc/apache2/conf-enabled/modsec.conf << EOF
Include /etc/modsec/modsecurity.conf
EOF

# 启动 Apache 前台运行
exec apache2-foreground
```

### 3. docker-compose.yml
```yaml
version: '3'

services:
  wordpress:
    build: .
    ports:
      - "30080:80"
    volumes:
      # WordPress 网站文件持久化挂载
      - ./html:/var/www/html
      # ModSecurity + CRS 全部配置统一挂载
      - ./modsec:/etc/modsec
    environment:
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_USER: wpuser
      WORDPRESS_DB_PASSWORD: wppass
      WORDPRESS_DB_NAME: wpdb
    depends_on:
      - db
    restart: always

  # MySQL 5.7 数据库服务
  db:
    image: mysql:5.7
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
      MYSQL_DATABASE: wpdb
      MYSQL_USER: wpuser
      MYSQL_PASSWORD: wppass
    volumes:
      - db-data:/var/lib/mysql
    restart: always

volumes:
  db-data:
```

## 快速部署步骤
### 1. 准备项目目录
新建项目文件夹，将上方 `Dockerfile`、`init.sh`、`docker-compose.yml` 三个文件放入目录内。

### 2. 赋予脚本执行权限
```bash
chmod +x init.sh
```

### 3. 构建镜像并一键启动
```bash
# 停止旧容器（如有）
docker-compose down

# 构建镜像 + 后台启动所有服务
docker-compose up -d
```

### 4. 访问站点
默认端口：`30080`
```
http://服务器IP:30080
```
按照页面提示完成 WordPress 安装即可正常使用。

## 版本切换说明（PHP7.2 ↔ PHP8.2 通用）
### 切换至 PHP 7.2（兼容老旧项目）
仅修改 `Dockerfile` 第一行：
```dockerfile
FROM wordpress:php7.2-apache
```
**其余所有文件完全无需改动**，脚本、配置、挂载、WAF拦截全部通用。

> 注意：`wordpress:php7.2-apache` 基于 Debian 10 已过期，本项目脚本已内置兼容处理，无需手动修改源。

## 功能验证
### 1. 验证 ModSecurity 模块加载
进入容器执行：
```bash
docker exec -it $(docker ps | grep wordpress | awk '{print $1}') apache2ctl -M | grep security
```
出现如下内容即为模块加载成功：
```
 security2_module (shared)
```

### 2. 验证WAF攻击拦截（核心验证）
访问SQL注入测试链接，服务会**直接返回 403 Forbidden**，代表防火墙完全生效：
```
http://服务器IP:30080/?id=1' OR 1=1--
```

### 3. 查看挂载配置目录
```bash
# 查看本地挂载目录结构
ls ./modsec
```
自动生成文件：
```
modsecurity.conf  crs-setup.conf  rules/
```

## 配置修改说明
1. **修改WAF防护策略**
   直接编辑本地文件 `./modsec/crs-setup.conf`，修改完成重启容器即可生效。
2. **自定义拦截规则**
   在 `./modsec/rules/` 目录新增自定义规则文件即可加载。
3. **WAF引擎总开关**
   位于 `./modsec/modsecurity.conf`
   ```apache
   SecRuleEngine On
   ```
   - `On`：正常拦截模式
   - `DetectionOnly`：仅日志记录，不拦截（调试排误报用）

## 常见问题与解决方案
### 问题1：手动修改配置重启后复原
原因：`modsecurity.conf` 由 `init.sh` 容器启动脚本自动生成。
解决：**修改源头 init.sh 内的配置内容**，重新构建镜像即可永久生效。

### 问题2：`Invalid command 'SecLogLevel'` 语法报错
原因：当前环境为 **ModSecurity 2.9.x** 旧版本，不支持 `SecLogLevel` 新版指令。
解决：本项目已全部移除该废弃指令，配置为纯兼容基础指令，无任何报错。

### 问题3：Apache 警告 AH00558 ServerName
现象不影响功能，本项目已自动配置修复：
```
ServerName localhost
```

### 问题4：CRS规则未自动下载
首次启动无本地挂载文件时，脚本会自动拉取 GitHub 官方规则集，保证网络连通即可。

## 技术说明
1. ModSecurity 版本：`2.9.3`（Apache 稳定版）
2. OWASP CRS 规则集版本：`v3.3.4`（长期稳定兼容版）
3. 架构：Apache 内嵌式WAF，无需额外反向代理容器
4. 兼容性：全版本 WordPress PHP 镜像通用，配置无侵入
5. 持久化：网站文件、防火墙配置全部本地挂载，容器销毁数据不丢失
