# WordPress + ModSecurity 2.3 一键部署说明

## 一、功能概述
本脚本实现 **WordPress 6.9 + ModSecurity 2.3 + CRS 2.2.9** 一键部署，为WordPress站点提供基础的Web应用防火墙（WAF）防护能力，可拦截SQL注入、单引号注入等常见攻击。

## 二、软件版本明细
| 软件/组件                | 版本          | 说明                     |
|--------------------------|---------------|--------------------------|
| WordPress                | 6.9 (内置6.9.3) | 基于官方wordpress:6.9-apache镜像 |
| ModSecurity (WAF核心)    | 2.3           | Apache 2.x兼容的稳定版本 |
| CRS (核心规则集)         | 2.2.9         | 适配ModSecurity 2.x的最后稳定版 |
| Apache                   | 2.4.66 (Debian) | 容器内置Web服务器        |
| PHP                      | 8.3.30        | 容器内置PHP版本          |

## 三、文件说明  [非最新版本]
### 1. Dockerfile（建议配套使用）
```dockerfile
# 基于官方WordPress 6.9 Apache镜像构建
FROM wordpress:6.9-apache

# 安装ModSecurity 2.3及依赖
RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    libapache2-mod-security2 \
    git \
    curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 启用ModSecurity模块
RUN a2enmod security2

# 设置ModSecurity默认配置目录
RUN mkdir -p /etc/modsecurity /tmp/modsecurity && \
    chown -R www-data:www-data /etc/modsecurity /tmp/modsecurity

# 暴露80端口
EXPOSE 80

# 启动Apache
CMD ["apache2-foreground"]
```

### 2. run-modsec-wp.sh（一键部署脚本）
```bash
#!/bin/bash
set -e
MODSEC_CRS_VOLUME="modsec-crs-rules"
MODSEC_CORE_VOLUME="modsec-core-config"
LOCAL_CRS_DIR="/opt/modsecurity-crs"
IMAGE_NAME="wordpress-modsec:6.9"
RANDOM_STR=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 6)
WP_DATA_VOLUME="WP_DATA_${RANDOM_STR}"
CONTAINER_NAME="wordpress-modsec-${RANDOM_STR}"

if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${IMAGE_NAME}$"; then
    echo "开始构建镜像 ${IMAGE_NAME}..."
    docker build -t ${IMAGE_NAME} . || { echo "❌ 镜像构建失败"; exit 1; }
else
    echo "✅ 镜像 ${IMAGE_NAME} 已存在，跳过构建"
fi

echo "创建/检查存储卷..."
docker volume create ${MODSEC_CRS_VOLUME} >/dev/null 2>&1
docker volume create ${MODSEC_CORE_VOLUME} >/dev/null 2>&1
docker volume create ${WP_DATA_VOLUME} >/dev/null 2>&1

echo "同步CRS 2.x规则（适配ModSec 2.3）..."
mkdir -p ${LOCAL_CRS_DIR}
if [ -d "${LOCAL_CRS_DIR}/.git" ]; then
    CRS_VERSION=$(cd ${LOCAL_CRS_DIR} && git describe --tags --abbrev=0 2>/dev/null || echo "unknown")
    if [ "${CRS_VERSION}" != "v2.2.9" ]; then
        echo "⚠️ 发现旧版本CRS (${CRS_VERSION})，删除后重新克隆2.2.9..."
        sudo rm -rf ${LOCAL_CRS_DIR}
        mkdir -p ${LOCAL_CRS_DIR}
        git clone --depth 1 --branch v2.2.9 https://github.com/coreruleset/coreruleset.git ${LOCAL_CRS_DIR} || { echo "❌ 本地克隆规则失败"; exit 1; }
    else
        echo "✅ CRS 2.2.9已存在，跳过克隆"
    fi
else
    echo "⚠️ CRS目录无git信息，重新克隆2.2.9..."
    git clone --depth 1 --branch v2.2.9 https://github.com/coreruleset/coreruleset.git ${LOCAL_CRS_DIR} || { echo "❌ 本地克隆规则失败"; exit 1; }
fi

if [ -f "${LOCAL_CRS_DIR}/modsecurity_crs_10_setup.conf.example" ]; then
    cp -f ${LOCAL_CRS_DIR}/modsecurity_crs_10_setup.conf.example ${LOCAL_CRS_DIR}/modsecurity_crs_10_setup.conf
else
    echo "❌ 未找到CRS 2.x配置文件，克隆可能失败"
    exit 1
fi
chmod -R 755 ${LOCAL_CRS_DIR}

sed -i 's/setvar:tx.paranoia_level=2/setvar:tx.paranoia_level=1/g' ${LOCAL_CRS_DIR}/modsecurity_crs_10_setup.conf
sed -i '/SecAction/a SecAction "id:900004,phase:1,nolog,pass,t:none,setvar:tx.allowed_methods=GET HEAD POST OPTIONS"' ${LOCAL_CRS_DIR}/modsecurity_crs_10_setup.conf

VOLUME_MOUNT=$(docker volume inspect -f '{{.Mountpoint}}' ${MODSEC_CRS_VOLUME})
cp -r ${LOCAL_CRS_DIR}/* ${VOLUME_MOUNT}/ || { echo "❌ 同步规则到存储卷失败"; exit 1; }
echo "✅ CRS 2.2.9规则（适配ModSec 2.3）同步完成"

echo "初始化ModSecurity 2.3核心配置..."
docker run --rm \
  -v ${MODSEC_CORE_VOLUME}:/etc/modsecurity \
  ${IMAGE_NAME} \
  sh -c "
    if [ -f /etc/modsecurity/modsecurity.conf ]; then
        cp /etc/modsecurity/modsecurity.conf /etc/modsecurity/modsecurity.conf.bak.\$(date +%Y%m%d%H%M%S)
        echo '✅ 已备份原有modsecurity.conf为modsecurity.conf.bak.$(date +%Y%m%d%H%M%S)'
    fi
    echo 'SecRuleEngine On' > /etc/modsecurity/modsecurity.conf
    echo 'SecRequestBodyAccess On' >> /etc/modsecurity/modsecurity.conf
    echo 'SecResponseBodyAccess On' >> /etc/modsecurity/modsecurity.conf
    echo 'SecResponseBodyMimeType text/plain text/html text/xml application/json' >> /etc/modsecurity/modsecurity.conf
    echo 'SecDataDir /tmp/modsecurity' >> /etc/modsecurity/modsecurity.conf
    echo 'SecTmpDir /tmp/modsecurity' >> /etc/modsecurity/modsecurity.conf
    echo 'SecUploadDir /tmp/modsecurity' >> /etc/modsecurity/modsecurity.conf
    echo 'SecAuditEngine RelevantOnly' >> /etc/modsecurity/modsecurity.conf
    echo 'SecAuditLogRelevantStatus ^(?:5|4(?!04))' >> /etc/modsecurity/modsecurity.conf
    echo 'SecAuditLogParts ABIJDEFHZ' >> /etc/modsecurity/modsecurity.conf
    echo 'SecAuditLog /var/log/apache2/modsec_audit.log' >> /etc/modsecurity/modsecurity.conf
    echo 'SecDebugLog /var/log/apache2/modsec_debug.log' >> /etc/modsecurity/modsecurity.conf
    echo 'SecDebugLogLevel 3' >> /etc/modsecurity/modsecurity.conf
    echo \"SecRule ARGS '\\'\\s*OR\\s*1=1\\'' \\\"id:1000,phase:2,deny,status:403,msg:'SQL Injection Attempt'\\\"\" >> /etc/modsecurity/modsecurity.conf
    echo \"SecRule ARGS_GET:id \\\"\\\\x27\\\" \\\"id:1001,phase:2,deny,status:403,msg:'Single Quote Injection Attempt'\\\"\" >> /etc/modsecurity/modsecurity.conf
    mkdir -p /tmp/modsecurity /var/log/apache2
    chown -R www-data:www-data /etc/modsecurity /tmp/modsecurity /var/log/apache2
    chmod 755 /etc/modsecurity/modsecurity.conf
    echo 'ServerName localhost' >> /etc/apache2/apache2.conf
" || { echo "❌ 核心配置初始化失败"; exit 1; }

if ! docker run --rm -v ${MODSEC_CORE_VOLUME}:/tmp/modsec ${IMAGE_NAME} sh -c "test -f /tmp/modsec/modsecurity.conf"; then
    echo "❌ 核心卷中未找到modsecurity.conf，初始化失败"
    exit 1
fi
echo "✅ ModSecurity 2.3核心配置（modsecurity.conf）已存在"

echo "清理旧容器..."
docker stop ${CONTAINER_NAME} >/dev/null 2>&1 || true
docker rm ${CONTAINER_NAME} >/dev/null 2>&1 || true

echo "启动WordPress + ModSecurity 2.3容器..."
docker run -d \
  --name ${CONTAINER_NAME} \
  -v ${MODSEC_CRS_VOLUME}:/etc/modsecurity-crs \
  -v ${MODSEC_CORE_VOLUME}:/etc/modsecurity \
  -v ${WP_DATA_VOLUME}:/var/www/html \
  -e WORDPRESS_DB_HOST=mysql:3306 \
  -e WORDPRESS_DB_USER=root \
  -e WORDPRESS_DB_PASSWORD=123456 \
  -e WORDPRESS_DB_NAME=wordpress \
  ${IMAGE_NAME} || { echo "❌ 容器启动失败"; exit 1; }

echo "\n🎉 部署完成：
- 本地CRS规则目录：${LOCAL_CRS_DIR}
- 容器名称：${CONTAINER_NAME}
- WP数据卷：${WP_DATA_VOLUME}
- ModSec规则卷（共用）：${MODSEC_CRS_VOLUME}
- ModSec核心配置卷：${MODSEC_CORE_VOLUME}
- 验证命令1：docker exec ${CONTAINER_NAME} ls /etc/modsecurity/modsecurity.conf
- 验证命令2：docker exec ${CONTAINER_NAME} apache2ctl -M | grep mod_security2
- 测试拦截：docker exec ${CONTAINER_NAME} curl -I -s http://localhost/?id=1%27 | grep HTTP"
```

## 四、使用方法

### 1. 前置条件
- 已安装Docker且Docker服务正常运行（`systemctl status docker` 确认）
- 当前用户拥有Docker执行权限（无需sudo，或已配置sudo免密）
- 已部署MySQL容器（需与脚本中环境变量匹配：主机mysql、端口3306、用户root、密码123456、数据库wordpress）
- 网络可访问GitHub（用于克隆CRS规则）

### 2. 部署步骤
1. 创建目录并放入文件
   ```bash
   mkdir -p /opt/wordpress-modsec && cd /opt/wordpress-modsec
   # 将Dockerfile和run-modsec-wp.sh放入该目录
   ```
2. 赋予脚本执行权限
   ```bash
   chmod +x run-modsec-wp.sh
   ```
3. 执行部署脚本
   ```bash
   sh run-modsec-wp.sh
   ```

### 3. 验证部署结果
#### （1）验证ModSecurity模块加载
```bash
# 替换为脚本输出的容器名称
docker exec 容器名称 apache2ctl -M | grep mod_security2
# 正常输出：mod_security2_module (shared)
```

#### （2）验证拦截规则生效
```bash
# 替换为脚本输出的容器名称
docker exec 容器名称 curl -I -s http://localhost/?id=1%27 | grep HTTP
# 正常输出：HTTP/1.1 403 Forbidden
```

#### （3）验证WordPress可访问
```bash
# 查看容器IP
docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 容器名称
# 浏览器访问 http://容器IP ，可进入WordPress安装页面
```

### 4. 常用运维命令
#### （1）查看容器日志
```bash
docker logs -f 容器名称
# 查看ModSecurity拦截日志
docker exec 容器名称 cat /var/log/apache2/modsec_audit.log
```

#### （2）修改ModSecurity配置
```bash
# 进入容器修改配置
docker exec -it 容器名称 bash
# 编辑核心配置
vim /etc/modsecurity/modsecurity.conf
# 重启Apache生效
apache2ctl restart
```

#### （3）停止/启动/删除容器
```bash
# 停止容器
docker stop 容器名称
# 启动容器
docker start 容器名称
# 删除容器（需先停止）
docker rm 容器名称
```

#### （4）备份/恢复ModSecurity配置
```bash
# 备份配置（脚本已自动备份，也可手动备份）
docker cp 容器名称:/etc/modsecurity/modsecurity.conf ./modsecurity.conf.bak
# 恢复配置
docker cp ./modsecurity.conf.bak 容器名称:/etc/modsecurity/modsecurity.conf
docker exec 容器名称 apache2ctl restart
```

## 五、关键说明
1. **数据持久化**：
   - WordPress数据存储在随机命名的Docker卷（WP_DATA_xxxxxx）中，容器删除后数据不丢失
   - ModSecurity规则和配置存储在固定卷中，可被多个容器共用
2. **规则防护范围**：
   - 默认拦截SQL注入（单引号注入、OR 1=1注入）
   - 可在`modsecurity.conf`中添加更多规则（如XSS、命令注入）增强防护
3. **CRS规则级别**：
   - 默认将CRS规则级别（paranoia_level）设为1（最低），避免误拦WordPress正常请求
   - 若需更高防护级别，可修改`/opt/modsecurity-crs/modsecurity_crs_10_setup.conf`中的`paranoia_level`为2/3/4
4. **兼容性**：
   - 本部署仅适配ModSecurity 2.3 + CRS 2.2.9，不兼容ModSecurity 3.x
   - 镜像基于官方wordpress:6.9-apache，兼容WordPress 6.9.x版本

## 六、常见问题
### 1. 执行脚本提示“克隆CRS规则失败”
- 原因：网络无法访问GitHub
- 解决：手动下载CRS 2.2.9压缩包并解压到`/opt/modsecurity-crs`
  ```bash
  wget https://github.com/coreruleset/coreruleset/archive/refs/tags/v2.2.9.tar.gz -O /tmp/crs-2.2.9.tar.gz
  mkdir -p /opt/modsecurity-crs
  tar -zxf /tmp/crs-2.2.9.tar.gz --strip-components=1 -C /opt/modsecurity-crs
  ```

### 2. 测试拦截返回500错误
- 原因：ModSecurity配置语法错误或目录权限不足
- 解决：重新执行脚本（脚本已修复配置语法和权限问题），或查看日志定位错误
  ```bash
  docker exec 容器名称 cat /var/log/apache2/error.log | grep modsec
  ```

### 3. Apache提示“AH00558: ServerName”警告
- 原因：未设置全局ServerName
- 解决：执行以下命令永久消除警告
  ```bash
  docker exec 容器名称 bash -c "echo 'ServerName localhost' >> /etc/apache2/apache2.conf && apache2ctl restart"
  ```

### 4. WordPress无法连接MySQL
- 原因：MySQL容器未启动/网络不通/账号密码错误
- 解决：
  1. 确认MySQL容器正常运行：`docker ps | grep mysql`
  2. 确认MySQL容器与WordPress容器在同一网络：`docker network connect 桥接网络 容器名称`
  3. 检查脚本中MySQL环境变量（DB_HOST/USER/PASSWORD/NAME）是否与MySQL配置匹配
