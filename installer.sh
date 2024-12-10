#!/bin/bash

# Check distribution and version
dist=$(source /etc/os-release && echo "$ID")
version=$(source /etc/os-release && echo "$VERSION_ID")

# Main script
FQDN="$1"
SSL="$2"
EMAIL="$3"
USERNAME="$4"
FIRSTNAME="$5"
LASTNAME="$6"
PASSWORD="$7"
WINGS="$8"

if [ -z "$FQDN" ] || [ -z "$SSL" ] || [ -z "$EMAIL" ] || [ -z "$USERNAME" ] || [ -z "$FIRSTNAME" ] || [ -z "$LASTNAME" ] || [ -z "$PASSWORD" ] || [ -z "$WINGS" ]; then
    echo "Error! Incorrect script usage."
    exit 1
fi

# OS compatibility check
echo "Checking your OS..."
if [[ "$dist:$version" =~ ubuntu:20.04|ubuntu:22.04|debian:11|debian:12 ]]; then
    echo "Starting Pterodactyl Panel auto-installation..."
    sleep 5
else
    echo "Your OS, $dist $version, is not supported."
    exit 1
fi

# Install dependencies
apt update && apt install -y certbot
case "$dist:$version" in
    ubuntu:20.04|ubuntu:22.04)
        apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg
        LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
        ;;
    debian:11|debian:12)
        apt -y install software-properties-common curl ca-certificates gnupg2 sudo lsb-release
        ;;
    *)
        echo "Unsupported OS version"
        exit 1
        ;;
esac

apt install -y mariadb-server redis-server nginx php8.1 php8.1-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip}
systemctl restart mariadb
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Configure MariaDB
DBPASSWORD=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 16 | head -n 1)
cat <<EOF | mariadb -u root
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DBPASSWORD';
CREATE DATABASE panel;
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

# Download and configure Pterodactyl Panel
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/download/v1.11.7/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/
cp .env.example .env
composer install --no-dev --optimize-autoloader --no-interaction
php artisan key:generate --force

# Configure panel environment
appurl="http${SSL:+s}://$FQDN"
php artisan p:environment:setup \
    --author="$EMAIL" \
    --url="$appurl" \
    --timezone="CET" \
    --telemetry=false \
    --cache="redis" \
    --session="redis" \
    --queue="redis" \
    --redis-host="localhost" \
    --redis-pass="null" \
    --redis-port="6379" \
    --settings-ui=true

php artisan p:environment:database \
    --host="127.0.0.1" \
    --port="3306" \
    --database="panel" \
    --username="pterodactyl" \
    --password="$DBPASSWORD"

php artisan migrate --seed --force
php artisan p:user:make \
    --email="$EMAIL" \
    --username="$USERNAME" \
    --name-first="$FIRSTNAME" \
    --name-last="$LASTNAME" \
    --password="$PASSWORD" \
    --admin=1

chown -R www-data:www-data /var/www/pterodactyl/*

# Configure services
curl -o /etc/systemd/system/pteroq.service https://raw.githubusercontent.com/amiruldev20/ippanel/main/configs/pteroq.service
(crontab -l; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -
systemctl enable --now redis-server
systemctl enable --now pteroq.service

# Configure Wings
if [ "$WINGS" == true ]; then
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    systemctl enable --now docker
    mkdir -p /etc/pterodactyl
    curl -L -o /usr/local/bin/wings \
        "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ \"$(uname -m)\" == \"x86_64\" ]] && echo \"amd64\" || echo \"arm64\")"
    curl -o /etc/systemd/system/wings.service \
        https://raw.githubusercontent.com/amiruldev20/ippanel/main/configs/wings.service
    chmod u+x /usr/local/bin/wings
fi

# Configure Nginx
rm -rf /etc/nginx/sites-enabled/default
if [ "$SSL" == true ]; then
    curl -o /etc/nginx/sites-enabled/pterodactyl.conf \
        https://raw.githubusercontent.com/amiruldev20/ippanel/main/configs/pterodactyl-nginx-ssl.conf
    sed -i "s@<domain>@$FQDN@g" /etc/nginx/sites-enabled/pterodactyl.conf
    systemctl stop nginx
    certbot certonly --standalone -d $FQDN --staple-ocsp --no-eff-email -m $EMAIL --agree-tos
    systemctl start nginx
else
    curl -o /etc/nginx/sites-enabled/pterodactyl.conf \
        https://raw.githubusercontent.com/amiruldev20/ippanel/main/configs/pterodactyl-nginx.conf
    sed -i "s@<domain>@$FQDN@g" /etc/nginx/sites-enabled/pterodactyl.conf
    systemctl restart nginx
fi

clear
echo "[!] Panel installed."
echo "[!] Panel URL: $appurl"
