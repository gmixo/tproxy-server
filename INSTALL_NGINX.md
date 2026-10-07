Готово. Создал deploy/install-nginx.sh — копию deploy/install.sh, адаптированную под Mode B (ко-хостинг под префиксом на существующем nginx). Файла deploy.sh в репозитории нет, так что за основу взят единственный установщик — install.sh; если хотите другое имя, переименуйте.

Что делает скрипт

Ставит и настраивает всё, кроме фронт-прокси:
- MTProxy (install-mtproxy.sh), сборку relay, /etc/tproxy-server/{config.json,profiles.json,token.key}, mtproxy.env с авто-детектом NAT;
- systemd-юниты tproxy-server, mtproxy, tproxy-firewall, refresh-mtproxy-config.{service,timer}, firewall.nft (порты 2398/8888 остаются loopback-only);
- проверку tproxy-server -check и ожидание /readyz.

Отличия от install.sh:
- Caddy не ставится вообще (нет скачивания, юзера caddy, /etc/caddy, caddy.service, drop-in, caddy validate).
- `/etc/nginx` не трогается — сниппет печатается в stdout; TLS/HSTS/сертификаты остаются вашими.
- --email убран (ACME больше нет), --site-dir убран.
- `--site-upstream` обязателен — loopback-бэкенд, который nginx уже отдаёт на / (или loopback-зеркало статики), чтобы in-prefix 404 совпадали с сайтом (иначе это отличимый признак, BASE_PATH.md §4).
- --base-path none и пустой унаследованный base_path отвергаются: ко-хостинг требует непустой префикс.
- Преflight-предупреждения, если caddy.service активен (конфликт за 80/443) или nginx не найден.

Запуск

sudo ./deploy/install-nginx.sh \
  --hostname example.com \
  --site-upstream http://127.0.0.1:3000 \
  --base-path my-slug        # без флага сгенерируется base32-слаг

В конце печатается готовый сниппет: map $http_upgrade $connection_upgrade, upstream tproxy_relay, server-level gzip on; client_max_body_size 4m; и location ^~ /<slug>/ — с ключевыми деталями из BASE_PATH §4 (proxy_pass без URI, X-Forwarded-For $remote_addr одним адресом, proxy_buffering off, proxy_read_timeout 90s, access_log off). Затем:

sudo nginx -t && sudo systemctl reload nginx

Если сайт — статика, скрипт печатает и пример loopback-зеркала (listen 127.0.0.1:3000), на который надо направить --site-upstream.

Проверка

- bash -n deploy/install-nginx.sh — синтаксис ок; подстановка sed сниппета проверена (nginx-переменные $host/$addr не съедаются).
- Полный прогон установщика не запускал — нужен x86_64 Debian/Ubuntu с root; статическая проверка только синтаксическая.
- Обновил ссылки на новый скрипт в README.md, BASE_PATH.md §4 и в списке bash -n в HARDENING.md.

Осталось на вашей стороне: указать реальный --site-upstream, вставить сниппет в существующий server {} и сделать nginx -t. Если у вас статика и mirror-блок на другом порту — поменяйте --site-upstream соответственно.
