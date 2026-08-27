# Установка вручну

Той самий базовий стан, що дає Ansible-роль, але покроково — якщо Ansible ви
не використовуєте або ставите на дистрибутив, який роль не підтримує.

Команди для AlmaLinux 9, від `root`. Замініть плейсхолдери:

```bash
DOMAIN=shop.example.com
APP=shop
SITE_USER=u_shop
SITE_HOME=/var/www/vhosts/$DOMAIN
```

## 1. Система

```bash
dnf install -y epel-release && dnf config-manager --set-enabled crb && dnf update -y
```

```bash
dnf install -y unzip zip p7zip p7zip-plugins tar zstd enca ImageMagick jpegoptim rclone git rsync logrotate firewalld bind-utils python3-pip && dnf install -y --enablerepo=crb libwebp-tools && pip3 install xlsx2csv
```

```bash
timedatectl set-timezone Europe/Kyiv
```

## 2. Користувач і теки

```bash
groupadd -f solweb && useradd -g solweb -d $SITE_HOME -s /bin/bash $SITE_USER
```

```bash
mkdir -p $SITE_HOME/{logs,httpdocs/public,system/letsencrypt} && chown -R $SITE_USER:solweb $SITE_HOME && chmod 0710 $SITE_HOME
```

## 3. PHP 8.2

```bash
dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm
```

```bash
dnf install -y php82 php82-php-fpm php82-php-cli php82-php-opcache php82-php-mysqlnd php82-php-mbstring php82-php-zip php82-php-imap php82-php-imagick php82-php-bcmath php82-php-intl php82-php-gd php82-php-soap php82-php-apcu php82-php-ffi php82-php-vips vips vips-tools
```

```bash
ln -sf /opt/remi/php82/root/bin/php /usr/local/bin/php
```

Значення, без яких платформа працює неправильно, — окремим drop-in
`/etc/opt/remi/php82/php.d/99-sol.ini` (зразок — у
`roles/sol_server_baseline/templates/php-sol.ini.j2`). Ключове:
`max_input_vars = 5000`, `memory_limit = 512M`, `upload_max_filesize = 300M`,
`post_max_size = 300M`, `opcache.save_comments = 1`.

Пул FPM `/etc/opt/remi/php82/php-fpm.d/$APP.conf` — зразок у
`templates/fpm-pool.conf.j2`. Дефолтний пул `www.conf` приберіть:

```bash
mv /etc/opt/remi/php82/php-fpm.d/www.conf /etc/opt/remi/php82/php-fpm.d/www.conf.backup
```

```bash
systemctl enable --now php82-php-fpm
```

Composer:

```bash
curl -fsSL https://getcomposer.org/download/latest-stable/composer.phar -o /usr/local/bin/composer && chmod 0755 /usr/local/bin/composer
```

## 4. MariaDB

Підключіть офіційний репозиторій MariaDB (зразок — `templates/mariadb.repo.j2`)
і встановіть сервер:

```bash
dnf install -y mariadb-server python3-PyMySQL && systemctl enable --now mariadb
```

Налаштування у `/etc/my.cnf.d/99-sol.cnf` (зразок —
`templates/mariadb-sol.cnf.j2`): `sql_mode` без `STRICT_TRANS_TABLES`,
`utf8mb4`, `innodb_flush_method = fsync`, `innodb_log_file_size = 512M`,
`innodb_ft_total_cache_size = 128M`, `innodb_buffer_pool_size` як гаряче ядро
(RAM/16, підлога 512M). Параметри статичні — задавайте їх **до** першого
старту служби, інакше знадобиться перезапуск.

База й користувач:

```sql
CREATE DATABASE shop CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'shop'@'localhost' IDENTIFIED BY '…';
GRANT ALL ON shop.* TO 'shop'@'localhost';
```

## 5. nginx

```bash
dnf install -y nginx && rm -f /etc/nginx/conf.d/default.conf && usermod -aG solweb nginx
```

Vhost `/etc/nginx/conf.d/$DOMAIN.conf` і формат логу
`/etc/nginx/conf.d/00-sol.conf` — зразки у `templates/vhost.conf.j2` та
`templates/nginx-sol.conf.j2`. Параметри Diffie-Hellman:

```bash
openssl dhparam -out /etc/nginx/dhparams.pem 2048
```

```bash
nginx -t && systemctl enable --now nginx
```

## 6. Meilisearch

```bash
curl -fL https://github.com/meilisearch/meilisearch/releases/download/v1.52.0/meilisearch-linux-amd64 -o /tmp/meilisearch && chmod +x /tmp/meilisearch
```

Перевірте, що бінарник запускається **до** того, як покладете його в систему —
офіційні збірки можуть вимагати новішого `glibc`, ніж є в EL9:

```bash
/tmp/meilisearch -V
```

```bash
mv /tmp/meilisearch /usr/local/bin/ && useradd -r -s /sbin/nologin -d /var/lib/meilisearch meilisearch && mkdir -p /var/lib/meilisearch/{data,dumps,snapshots} && chown -R meilisearch:meilisearch /var/lib/meilisearch
```

Конфіг `/etc/meilisearch.toml` і юніт `/etc/systemd/system/meilisearch.service`
— зразки у `templates/meilisearch.toml.j2` і `templates/meilisearch.service.j2`.
Master key обов'язковий, від 16 байтів.

```bash
systemctl enable --now meilisearch
```

## 7. TLS

Спершу переведіть `A`/`AAAA`-записи домену на цей сервер, потім:

```bash
dnf install -y certbot
```

```bash
certbot certonly -n --webroot -w $SITE_HOME/system/letsencrypt -m admin@example.com --agree-tos -d $DOMAIN -d www.$DOMAIN --cert-name $DOMAIN
```

Після випуску додайте в vhost блок з `ssl_certificate` і редирект з 80-го
порту (зразок — той самий `templates/vhost.conf.j2`), а також хук
перезавантаження nginx після продовження:

```bash
printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh && chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```

## 8. firewalld

```bash
systemctl enable --now firewalld && firewall-cmd --permanent --add-service={ssh,http,https} && firewall-cmd --reload
```

## 9. Ротація логів

Логи сайту лежать поза `/var/log`, тож дистрибутивні правила їх не бачать.
Зразок — `templates/logrotate-site.j2`, покласти у
`/etc/logrotate.d/sol-$APP`.

## 10. Воркери Messenger

Обов'язковий крок після того, як код магазину лежить у теці сайту: без воркерів
не йде пошта, не працює розклад і не виконуються бекапи (див. «Воркери
Messenger» у `requirements.md`). Три юніти — по одному на транспорт, зразок —
`roles/sol_server_baseline/templates/messenger-worker.service.j2`.

Обгортка консолі, щоб юніти й крон не згадували повний шлях і версію PHP:

```bash
printf '#!/bin/bash\nexec /usr/local/bin/php %s/httpdocs/bin/console "$@"\n' "$SITE_HOME" > /usr/local/bin/syli && chmod 0755 /usr/local/bin/syli
```

`/etc/systemd/system/sol-messenger-async.service` і
`sol-messenger-scheduler_default.service` (відрізняються лише ім'ям транспорту):

```ini
[Unit]
Description=Messenger worker (async)
After=network.target

[Service]
User=$SITE_USER
Group=solweb
ExecStart=/usr/local/bin/syli messenger:consume async \
    --time-limit=3600 --memory-limit=512M --failure-limit=5
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/sol-messenger-heavy.service` — одна задача на процес,
після неї воркер виходить і systemd піднімає свіжий; `TimeoutStopSec` дає
поточній задачі дожити при зупинці юніта:

```ini
[Unit]
Description=Messenger worker (heavy)
After=network.target

[Service]
User=$SITE_USER
Group=solweb
ExecStart=/usr/local/bin/syli messenger:consume heavy \
    --limit=1 --memory-limit=512M --failure-limit=1
TimeoutStopSec=36000
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now sol-messenger-async sol-messenger-scheduler_default sol-messenger-heavy
```

Після кожного оновлення коду — `syli messenger:stop-workers`: воркери
завершують поточне повідомлення, systemd піднімає їх уже з новим кодом.

## 11. Перевірка

```bash
bash scripts/check-server.sh
```
