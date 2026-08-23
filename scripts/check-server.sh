#!/usr/bin/env bash
#
# Перевірка сервера на відповідність вимогам магазину на платформі sol.parts.
# Нічого не змінює: тільки читає стан і друкує звіт.
#
#   bash check-server.sh
#
# Код виходу: 0 — усе гаразд або лише попередження, 1 — є критичні пункти.

set -uo pipefail

PHP_BIN="${PHP_BIN:-}"
MEILI_ADDR="${MEILI_ADDR:-127.0.0.1:7700}"

fails=0
warns=0

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_fail=$'\033[31m'; c_off=$'\033[0m'
[ -t 1 ] || { c_ok=""; c_warn=""; c_fail=""; c_off=""; }

ok()   { printf '  %s✓%s %s\n' "$c_ok" "$c_off" "$1"; }
warn() { printf '  %s!%s %s\n' "$c_warn" "$c_off" "$1"; warns=$((warns + 1)); }
fail() { printf '  %s✗%s %s\n' "$c_fail" "$c_off" "$1"; fails=$((fails + 1)); }
head2() { printf '\n%s\n' "$1"; }

# Порівняння версій: «чи $1 не менше за $2».
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

# ── ОС і залізо ──────────────────────────────────────────────────────────────
head2 "Операційна система"

if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '  %s %s (%s)\n' "${NAME:-?}" "${VERSION_ID:-?}" "$(uname -m)"
    case "${ID_LIKE:-$ID} ${ID:-}" in
        *rhel*|*fedora*|*centos*)
            if ver_ge "${VERSION_ID%%.*}" 9; then
                case "${ID:-}" in
                    almalinux) ok "перевірена ОС" ;;
                    *) warn "магазини ми супроводжуємо на AlmaLinux 9; тут інший дистрибутив сімейства RHEL 9 — вимоги ті самі, але досвіду з ним немає" ;;
                esac
            else
                fail "потрібен AlmaLinux 9 або інший дистрибутив сімейства RHEL 9 (виявлено ${VERSION_ID})"
            fi
            ;;
        *) warn "роль перевірена на AlmaLinux 9; тут інше сімейство — усе ставиться вручну" ;;
    esac
else
    warn "не вдалося визначити дистрибутив"
fi

cpu=$(nproc 2>/dev/null || echo 0)
ram_mb=$(awk '/MemTotal/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null || echo 0)
disk_gb=$(df -BG --output=size / 2>/dev/null | tail -n1 | tr -dc '0-9')
disk_gb=${disk_gb:-0}

printf '  %s CPU, %s МБ RAM, %s ГБ на /\n' "$cpu" "$ram_mb" "$disk_gb"
[ "$cpu" -ge 4 ]        || warn "менше 4 CPU — вистачить лише для невеликого каталогу"
[ "$ram_mb" -ge 7500 ]  || warn "менше 8 ГБ RAM — MariaDB, Meilisearch і PHP-FPM ділять одну пам'ять"
[ "$disk_gb" -ge 75 ]   || warn "менше 80 ГБ диска — місце з'їдають фото каталогу"

tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)
[ -n "$tz" ] && printf '  часова зона: %s\n' "$tz"

if command -v getenforce >/dev/null 2>&1; then
    selinux=$(getenforce)
    case "$selinux" in
        Enforcing) warn "SELinux enforcing — стек у цьому режимі не перевірявся, знадобляться власні контексти" ;;
        *) ok "SELinux: $selinux" ;;
    esac
fi

# ── PHP ──────────────────────────────────────────────────────────────────────
head2 "PHP"

if [ -z "$PHP_BIN" ]; then
    for candidate in /usr/local/bin/php /opt/remi/php82/root/bin/php php82 php; do
        if command -v "$candidate" >/dev/null 2>&1; then PHP_BIN="$candidate"; break; fi
    done
fi

if [ -z "$PHP_BIN" ]; then
    fail "PHP не знайдено (шукали /usr/local/bin/php, php82, php)"
else
    php_ver=$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null)
    printf '  %s → %s\n' "$PHP_BIN" "${php_ver:-?}"
    if ver_ge "${php_ver:-0}" 8.2; then
        ok "версія 8.2+"
    else
        fail "потрібен PHP 8.2 або новіший"
    fi

    modules=$("$PHP_BIN" -m 2>/dev/null | tr 'A-Z' 'a-z')
    missing=""
    for ext in bcmath curl dom gd iconv imagick imap intl json libxml mbstring mysqli openssl pdo_mysql simplexml soap zip; do
        printf '%s\n' "$modules" | grep -qx "$ext" || missing="$missing $ext"
    done
    printf '%s\n' "$modules" | grep -q 'opcache' || missing="$missing opcache"
    if [ -n "$missing" ]; then
        fail "немає розширень:$missing"
    else
        ok "всі обов'язкові розширення на місці"
    fi

    printf '%s\n' "$modules" | grep -qx "apcu" || warn "немає apcu — локальний кеш процесу"
    printf '%s\n' "$modules" | grep -qx "vips" || warn "немає vips — обробка фото піде повільнішим шляхом"

    check_ini() { # ім'я, мінімум-в-байтах-або-число, людський опис
        local name="$1" want="$2" desc="$3" got
        got=$("$PHP_BIN" -r "echo ini_get('$name');" 2>/dev/null)
        local got_num=$got
        case "$got" in
            *[Mm]) got_num=$(( ${got%[Mm]} * 1024 * 1024 )) ;;
            *[Gg]) got_num=$(( ${got%[Gg]} * 1024 * 1024 * 1024 )) ;;
        esac
        if [ -n "$got_num" ] && [ "$got_num" -ge "$want" ] 2>/dev/null; then
            ok "$name = $got"
        else
            fail "$name = ${got:-не задано} (потрібно щонайменше $desc)"
        fi
    }

    check_ini max_input_vars 5000 "5000 — інакше адмінка мовчки губить частину форми налаштувань"
    check_ini memory_limit $((512 * 1024 * 1024)) "512M"
    check_ini upload_max_filesize $((100 * 1024 * 1024)) "100M для завантаження прайсів"
    check_ini post_max_size $((100 * 1024 * 1024)) "100M"

    save_comments=$("$PHP_BIN" -r "echo ini_get('opcache.save_comments');" 2>/dev/null)
    if [ "$save_comments" = "1" ] || [ -z "$save_comments" ]; then
        ok "opcache.save_comments увімкнено"
    else
        fail "opcache.save_comments вимкнено — зламається читання атрибутів Doctrine/Symfony"
    fi
fi

if pgrep -f 'php-fpm: master' >/dev/null 2>&1; then
    ok "PHP-FPM запущено"
else
    warn "PHP-FPM не знайдено серед процесів"
fi

# ── MariaDB ──────────────────────────────────────────────────────────────────
head2 "MariaDB"

if command -v mariadb >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1; then
    db_cli=$(command -v mariadb || command -v mysql)
    db_ver=$("$db_cli" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    printf '  %s\n' "${db_ver:-версію не визначено}"
    if ver_ge "${db_ver:-0}" 10.6; then
        ok "версія 10.6+"
    else
        warn "рекомендовано MariaDB 10.6 або новішу"
    fi

    if vars=$("$db_cli" -N -B -e "SELECT @@sql_mode, @@ft_min_word_len, @@character_set_server;" 2>/dev/null); then
        sql_mode=$(printf '%s' "$vars" | cut -f1)
        ft_min=$(printf '%s' "$vars" | cut -f2)
        charset=$(printf '%s' "$vars" | cut -f3)

        case "$sql_mode" in
            *STRICT_TRANS_TABLES*) fail "sql_mode містить STRICT_TRANS_TABLES — ламає імпорт прайсів" ;;
            *) ok "sql_mode без строгого режиму" ;;
        esac
        [ "$ft_min" = "1" ] && ok "ft_min_word_len = 1" \
            || fail "ft_min_word_len = ${ft_min} — пошук не бачитиме коротких артикулів (M8, R15)"
        [ "$charset" = "utf8mb4" ] && ok "character_set_server = utf8mb4" \
            || fail "character_set_server = ${charset} (потрібно utf8mb4)"
    else
        warn "не вдалося підключитись до БД — запустіть скрипт від root, щоб перевірити налаштування"
    fi
else
    fail "MariaDB не знайдено"
fi

# ── nginx ────────────────────────────────────────────────────────────────────
head2 "nginx"

if command -v nginx >/dev/null 2>&1; then
    nginx_ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    printf '  %s\n' "${nginx_ver:-версію не визначено}"
    if ver_ge "${nginx_ver:-0}" 1.25.1; then
        ok "версія підтримує директиву http2 on"
    else
        warn "nginx старший за 1.25.1 — HTTP/2 доведеться вмикати старим синтаксисом"
    fi
    if nginx -t >/dev/null 2>&1; then
        ok "конфігурація валідна"
    else
        warn "nginx -t повертає помилку (можливо, потрібні права root)"
    fi
else
    fail "nginx не знайдено"
fi

for port in 80 443; do
    if (command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$port ") ; then
        ok "порт $port слухається"
    else
        warn "порт $port не слухається"
    fi
done

# ── Meilisearch ──────────────────────────────────────────────────────────────
head2 "Meilisearch"

if command -v meilisearch >/dev/null 2>&1 || [ -x /usr/local/bin/meilisearch ]; then
    meili_bin=$(command -v meilisearch || echo /usr/local/bin/meilisearch)
    if meili_ver=$("$meili_bin" -V 2>/dev/null); then
        ok "$meili_ver"
    else
        fail "бінарник є, але не запускається — імовірно, зібраний під новіший glibc (див. docs/requirements.md)"
    fi
else
    fail "Meilisearch не знайдено — без нього вітрина не шукає товари"
fi

if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 5 "http://$MEILI_ADDR/health" >/dev/null 2>&1; then
        ok "сервіс відповідає на $MEILI_ADDR"
    else
        warn "сервіс не відповідає на $MEILI_ADDR"
    fi
fi

# ── Утиліти ──────────────────────────────────────────────────────────────────
head2 "Утиліти обробки прайсів і зображень"

check_tool() {
    if command -v "$1" >/dev/null 2>&1; then ok "$1"; else warn "немає $1 — $2"; fi
}

check_tool composer "встановлення залежностей платформи"
check_tool enca     "визначення кодування текстових прайсів"
check_tool xlsx2csv "імпорт великих xlsx"
check_tool unzip    "розпакування прайсів"
check_tool 7za      "розпакування прайсів у 7z"
check_tool convert  "обробка зображень (ImageMagick)"
check_tool jpegoptim "стиснення jpeg"
check_tool webpmux  "робота з метаданими webp"
check_tool rclone   "копіювання фото в об'єктне сховище"

# ── Воркери Messenger ────────────────────────────────────────────────────────
# Без них не йде пошта, не працює розклад і бекапи — черга лише накопичується,
# без жодної помилки на сайті. Юніти іменуються sol-messenger-<транспорт>
# (роль) або messenger.consume.<app>.<транспорт> (платформний деплой).
head2 "Воркери Messenger"

check_worker() {
    unit=$(systemctl list-units --all --plain --no-legend "sol-messenger-$1.service" "messenger.consume.*.$1.service" 2>/dev/null | awk 'NR==1{print $1}')
    if [ -z "$unit" ]; then
        warn "немає юніта воркера $1 — $2"
    elif systemctl is-active --quiet "$unit"; then
        ok "$unit активний"
    else
        warn "$unit не запущений — $2"
    fi
}

check_worker async             "пошта, SMS, обміни із зовнішніми системами"
check_worker scheduler_default "розклад: періодичні команди платформи"
check_worker heavy             "довгі задачі: бекап зображень, карта сайту"

# ── Підсумок ─────────────────────────────────────────────────────────────────
printf '\n'
if [ "$fails" -gt 0 ]; then
    printf '%sКритичних пунктів: %s, попереджень: %s%s\n' "$c_fail" "$fails" "$warns" "$c_off"
    printf 'Вимоги повністю: docs/requirements.md\n'
    exit 1
fi

if [ "$warns" -gt 0 ]; then
    printf '%sКритичних пунктів немає, попереджень: %s%s\n' "$c_warn" "$warns" "$c_off"
else
    printf '%sСервер відповідає базовим вимогам.%s\n' "$c_ok" "$c_off"
fi
exit 0
