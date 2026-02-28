#!/usr/bin/env bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

generate_secret() {
	openssl rand -hex 16
}

sanitize_user_key() {
	local raw="$1"
	local clean
	clean=$(printf '%s' "$raw" | tr ' ' '_' | sed -E 's/[^a-zA-Z0-9_-]/_/g')
	printf '%s' "$clean"
}

detect_install_dir() {
	local dir="$1"
	if [[ -n "$dir" ]] && [[ -f "${dir}/telemt.toml" ]]; then
		printf '%s' "$dir"
		return
	fi
	if [[ -f "./telemt.toml" ]]; then
		printf '%s' "$(pwd)"
		return
	fi
	err "Не найден telemt.toml. Укажите каталог установки первым аргументом."
}

get_tls_domain() {
	local file="$1"
	grep -E '^[[:space:]]*tls_domain[[:space:]]*=' "$file" \
		| head -n1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/'
}

get_listen_port() {
	local dir="$1"
	local port=""
	if [[ -f "${dir}/.listen_port" ]]; then
		port=$(tr -d '\n\r' < "${dir}/.listen_port")
	fi
	if [[ -z "$port" ]] && [[ -f "${dir}/docker-compose.yml" ]]; then
		port=$(awk '
			/ports:/ {in_ports=1; next}
			in_ports && $0 ~ /:443/ {
				if (match($0, /([0-9]+)[[:space:]]*:[[:space:]]*443/, m)) {
					print m[1]; exit
				}
			}
			in_ports && $0 ~ /^[^[:space:]-]/ {in_ports=0}
		' "${dir}/docker-compose.yml")
	fi
	[[ -z "$port" ]] && port="443"
	printf '%s' "$port"
}

insert_user() {
	local file="$1"
	local user="$2"
	local secret="$3"
	if grep -Eq "^[[:space:]]*${user}[[:space:]]*=" "$file"; then
		err "Пользователь '${user}' уже существует в ${file}"
	fi
	awk -v user="$user" -v secret="$secret" '
		BEGIN { added=0; in_users=0 }
		/^\[access\.users\][[:space:]]*$/ { in_users=1; print; next }
		in_users && /^\[/ && $0 !~ /^\[access\.users\]/ {
			if (!added) { print user " = \"" secret "\""; added=1 }
			in_users=0
		}
		{ print }
		END {
			if (in_users && !added) { print user " = \"" secret "\""; added=1 }
			if (!added) { exit 2 }
		}
	' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

print_link() {
	local secret="$1"
	local tls_domain="$2"
	local listen_port="$3"
	local domain_hex long_secret server_ip link

	domain_hex=$(printf '%s' "$tls_domain" | od -An -tx1 | tr -d ' \n')
	if [[ "$secret" =~ ^[0-9a-fA-F]{32}$ ]]; then
		long_secret="ee${secret}${domain_hex}"
	else
		long_secret="$secret"
	fi

	server_ip=""
	for url in https://ifconfig.me/ip https://icanhazip.com https://api.ipify.org https://checkip.amazonaws.com; do
		raw=$(curl -s --connect-timeout 3 "$url" 2>/dev/null | tr -d '\n\r')
		if [[ -n "$raw" ]] && [[ ! "$raw" =~ [[:space:]] ]] && [[ ! "$raw" =~ (error|timeout|upstream|reset|refused) ]] && [[ "$raw" =~ ^([0-9.]+|[0-9a-fA-F:]+)$ ]]; then
			server_ip="$raw"
			break
		fi
	done
	if [[ -z "$server_ip" ]]; then
		server_ip="YOUR_SERVER_IP"
		warn "Не удалось определить внешний IP. Подставьте IP сервера в ссылку вручную."
	fi

	link="tg://proxy?server=${server_ip}&port=${listen_port}&secret=${long_secret}"
	echo ""
	echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
	echo -e "${GREEN}║  Новый доступ (Fake TLS)                                ║${NC}"
	echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
	echo ""
	echo -e "  ${GREEN}${link}${NC}"
	echo ""
}

main() {
	local arg1="${1:-}"
	local install_dir user_key raw_key secret tls_domain listen_port

	if [[ -n "$arg1" ]] && [[ -f "${arg1}/telemt.toml" ]]; then
		install_dir="$arg1"
		shift
	else
		install_dir="$(detect_install_dir "")"
	fi

	raw_key="${1:-}"
	if [[ -z "$raw_key" ]] && [[ -t 0 ]]; then
		echo -n "Имя пользователя (для отметки в telemt.toml): "
		read -r raw_key
	fi
	[[ -z "$raw_key" ]] && raw_key="user$(date +%s)"

	user_key="$(sanitize_user_key "$raw_key")"
	[[ -z "$user_key" ]] && err "Не удалось сформировать имя пользователя."
	if [[ "$user_key" != "$raw_key" ]]; then
		warn "Имя пользователя нормализовано: ${user_key}"
	fi

	secret="$(generate_secret)"

	tls_domain="$(get_tls_domain "${install_dir}/telemt.toml")"
	[[ -z "$tls_domain" ]] && err "tls_domain не найден в ${install_dir}/telemt.toml"
	listen_port="$(get_listen_port "$install_dir")"

	insert_user "${install_dir}/telemt.toml" "$user_key" "$secret"
	info "Добавлен пользователь '${user_key}' в ${install_dir}/telemt.toml"

	if command -v docker &>/dev/null; then
		(
			cd "$install_dir" && docker compose restart telemt >/dev/null 2>&1
		) && info "Telemt перезапущен (конфиг применён)." \
			|| warn "Не удалось перезапустить Telemt. Перезапустите вручную: docker compose restart telemt"
	else
		warn "Docker не найден. Перезапустите Telemt вручную: docker compose restart telemt"
	fi

	print_link "$secret" "$tls_domain" "$listen_port"
	info "Не публикуйте ссылку публично."
}

main "$@"
