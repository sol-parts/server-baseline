# Changelog

## 1.0.0

Перший публічний випуск.

- Ansible-роль `sol_server_baseline`: система, користувач і теки сайту,
  PHP 8.2 (Remi) з пулом FPM, MariaDB 10.6, nginx із vhost магазину,
  Meilisearch, Let's Encrypt, firewalld, ротація логів.
- Опційний блок runtime: обгортка консольних команд і воркери черги.
- Тег `verify` — перевірка сервера без змін.
- `scripts/check-server.sh` — та сама перевірка без Ansible.
- Документація: вимоги до сервера й покрокова установка вручну.
