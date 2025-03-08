#!/usr/bin/env bash

# 颜色输出
GREEN="\e[32m"
RED="\e[31m"
RESET="\e[0m"

# 日志输出函数
log_info() { echo -e "${GREEN}[INFO] $1${RESET}"; }
log_error() { echo -e "${RED}[ERROR] $1${RESET}"; exit 1; }

# 基础变量
APP="Nginx Proxy Manager"
var_tags="proxy"
var_cpu="2"
var_ram="1024"
var_disk="4"
var_os="debian"
var_version="12"
var_unprivileged="1"

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    log_error "请使用 root 用户执行此脚本。"
fi

log_info "开始安装 ${APP}"

# 检查 `systemctl` 命令是否存在
if ! command -v systemctl &> /dev/null; then
    log_error "systemctl 命令未找到，请检查你的系统环境。"
fi

# 停止已有的 Nginx Proxy Manager
log_info "停止已有的 Nginx Proxy Manager"
systemctl stop openresty 2>/dev/null
systemctl stop npm 2>/dev/null

# 清理旧文件
log_info "清理旧的 Nginx Proxy Manager 版本"
rm -rf /app /var/www/html /etc/nginx /var/log/nginx /var/lib/nginx /var/cache/nginx

# 获取最新的 NPM 版本
RELEASE=$(curl -s https://api.github.com/repos/NginxProxyManager/nginx-proxy-manager/releases/latest | grep "tag_name" | awk -F '"' '{print substr($4,2)}')

# 下载并解压
log_info "下载 Nginx Proxy Manager v${RELEASE}"
wget -q https://codeload.github.com/NginxProxyManager/nginx-proxy-manager/tar.gz/v${RELEASE} -O - | tar -xz
cd nginx-proxy-manager-${RELEASE} || log_error "下载 NPM 失败，请检查网络连接。"

# 环境设置
log_info "配置环境"
ln -sf /usr/bin/python3 /usr/bin/python
ln -sf /usr/bin/certbot /opt/certbot/bin/certbot
ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx
ln -sf /usr/local/openresty/nginx/ /etc/nginx

# 修改配置
log_info "更新 Nginx Proxy Manager 配置"
sed -i "s|\"version\": \"0.0.0\"|\"version\": \"$RELEASE\"|" backend/package.json
sed -i "s|\"version\": \"0.0.0\"|\"version\": \"$RELEASE\"|" frontend/package.json

# 处理 Nginx 配置
log_info "修正 Nginx 配置"
find "$(pwd)" -type f -name "*.conf" -exec sed -i 's+include conf.d+include /etc/nginx/conf.d+g' {} \;

# 目录创建
mkdir -p /var/www/html /etc/nginx/logs /tmp/nginx/body /run/nginx /data/nginx /data/custom_ssl /data/logs \
         /data/access /data/nginx/default_host /data/nginx/default_www /data/nginx/proxy_host /data/nginx/redirection_host \
         /data/nginx/stream /data/nginx/dead_host /data/nginx/temp /var/lib/nginx/cache/public /var/lib/nginx/cache/private \
         /var/cache/nginx/proxy_temp

# 设定权限
chmod -R 777 /var/cache/nginx
chown root /tmp/nginx

# 生成默认证书
if [ ! -f /data/nginx/dummycert.pem ] || [ ! -f /data/nginx/dummykey.pem ]; then
    log_info "生成自签名 SSL 证书"
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 -subj "/O=Nginx Proxy Manager/OU=Dummy Certificate/CN=localhost" \
        -keyout /data/nginx/dummykey.pem -out /data/nginx/dummycert.pem
fi

# 安装 pnpm
if ! command -v pnpm &> /dev/null; then
    log_info "安装 pnpm"
    npm install -g pnpm@8.15
fi

# 前端构建
log_info "构建前端"
cd frontend || log_error "前端目录不存在"
pnpm install
pnpm upgrade
pnpm run build
cp -r dist/* /app/frontend
cp -r app-images/* /app/frontend/images

# 后端初始化
log_info "初始化后端"
cd /app || log_error "后端目录不存在"
rm -rf /app/config/default.json
if [ ! -f /app/config/production.json ]; then
    cat <<'EOF' > /app/config/production.json
{
  "database": {
    "engine": "knex-native",
    "knex": {
      "client": "sqlite3",
      "connection": {
        "filename": "/data/database.sqlite"
      }
    }
  }
}
EOF
fi

pnpm install

# 启动服务
log_info "启动 Nginx Proxy Manager"
systemctl enable --now openresty
systemctl enable --now npm

log_info "Nginx Proxy Manager 安装完成 🎉"
