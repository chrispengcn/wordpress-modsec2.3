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
# ========== 核心修改部分开始 ==========
docker run --rm \
  -v ${MODSEC_CORE_VOLUME}:/etc/modsecurity \
  ${IMAGE_NAME} \
  sh -c "
    # 1. 备份原有配置文件（带时间戳，避免覆盖）
    if [ -f /etc/modsecurity/modsecurity.conf ]; then
        cp /etc/modsecurity/modsecurity.conf /etc/modsecurity/modsecurity.conf.bak.\$(date +%Y%m%d%H%M%S)
        echo '✅ 已备份原有modsecurity.conf为modsecurity.conf.bak.$(date +%Y%m%d%H%M%S)'
    fi
    # 2. 通过echo命令逐行生成新配置（精准匹配指定内容）
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
    # 3. 创建必要目录并授权
    mkdir -p /tmp/modsecurity /var/log/apache2
    chown -R www-data:www-data /etc/modsecurity /tmp/modsecurity /var/log/apache2
    chmod 755 /etc/modsecurity/modsecurity.conf
    # 4. 消除Apache ServerName警告
    echo 'ServerName localhost' >> /etc/apache2/apache2.conf
" || { echo "❌ 核心配置初始化失败"; exit 1; }
# ========== 核心修改部分结束 ==========

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

echo -e "\n🎉 部署完成：
- 本地CRS规则目录：${LOCAL_CRS_DIR}
- 容器名称：${CONTAINER_NAME}
- WP数据卷：${WP_DATA_VOLUME}
- ModSec规则卷（共用）：${MODSEC_CRS_VOLUME}
- ModSec核心配置卷：${MODSEC_CORE_VOLUME}
- 验证命令1：docker exec ${CONTAINER_NAME} ls /etc/modsecurity/modsecurity.conf
- 验证命令2：docker exec ${CONTAINER_NAME} apache2ctl -M | grep mod_security2
- 测试拦截：docker exec ${CONTAINER_NAME} curl -I -s http://localhost/?id=1%27 | grep HTTP"
