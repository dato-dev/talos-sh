#!/usr/bin/env bash
#
# Развёртывание и расширение кластера Talos Linux на Proxmox.
#
#   bootstrap — первичная установка с нуля: генерирует секреты, раскатывает
#               конфиг на все ноды, инициализирует etcd.
#   join      — добавление нод в работающий кластер: конфиг снимается с живой
#               ноды, секреты НЕ перегенерируются, bootstrap НЕ вызывается.
#
# Разделение на две команды сделано намеренно. Прежняя версия скрипта всегда
# генерировала новые секреты и всегда вызывала bootstrap — на работающем
# кластере это создавало несовместимый набор PKI и разрушало etcd.
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[+]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[-]${NC} $1" >&2; }
die() {
    log_error "$1"
    exit 1
}

DEFAULT_CLUSTER_NAME="talos-proxmox-cluster"
DEFAULT_CONFIG_DIR="./talos-proxmox-cluster"
DEFAULT_TIMEOUT=900
POLL_INTERVAL=10

# Каталог для конфигов с секретами, снятых с живого кластера.
work_dir=""
# Тест в конце обработчика EXIT подменил бы код возврата скрипта, поэтому if.
cleanup() {
    if [ -n "$work_dir" ]; then
        rm -rf "$work_dir"
    fi
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Talos cluster deployment helper.

USAGE
  talos.sh bootstrap --controlplane <ips> [--workers <ips>] [options]
  talos.sh join --endpoint <ip> [--controlplane <ips>] [--workers <ips>] [options]

  Every option has a short and a long form; --opt=value works too.

BOOTSTRAP OPTIONS
  -c, --controlplane <ips>        Control-plane IPs, comma-separated (required)
  -w, --workers <ips>             Worker IPs, comma-separated
  -n, --cluster-name <name>       Cluster name (default: talos-proxmox-cluster)
  -i, --install-image <image>     Installer image
  -k, --kubernetes-version <ver>  Kubernetes version
  -d, --output-dir <dir>          Output directory (default: ./talos-proxmox-cluster)
  -f, --force                     Overwrite an existing output directory

JOIN OPTIONS
  -e, --endpoint <ip>             IP of any node already in the cluster (required)
  -c, --controlplane <ips>        New control-plane IPs, comma-separated
  -w, --workers <ips>             New worker IPs, comma-separated
  -i, --install-image <image>     Installer image override. By default the image is
                                  taken from the source node and its tag is bumped
                                  to the version actually running there, because
                                  'talosctl upgrade' does not rewrite install.image.
  -p, --patch <file>              Extra config patch applied to the new nodes
                                  (talosctl patch format, JSON patch or strategic
                                  merge). Use this to assign static addresses.
  -K, --keep-network              Keep the source node's static network config.
                                  Dangerous: every new node would get the source
                                  node's IP. Off by default.
  -t, --talosconfig <file>        Path to talosconfig (default: $TALOSCONFIG)

COMMON OPTIONS
  -T, --timeout <sec>             Timeout for each wait, in seconds (default: 900)
  -h, --help                      This help

EXAMPLES
  talos.sh bootstrap --controlplane 192.168.1.10 --workers 192.168.1.11,192.168.1.12
  talos.sh join --endpoint 192.168.1.40 --controlplane 192.168.1.49,192.168.1.52
  talos.sh join -e 192.168.1.40 -w 192.168.1.60
  talos.sh join --endpoint=192.168.1.40 --workers=192.168.1.60 \
      --install-image=docker.io/dato1/talos-nocloud-installer:v1.13.7
EOF
    exit 1
}

# Разворачивает --opt=value в два аргумента, чтобы разбор был единообразным.
# Через глобальный массив, а не через подстановку команды: перевод строки
# внутри аргумента не должен ломать разбор.
normalize_long_args() {
    NORMALIZED_ARGS=()
    local arg
    for arg in "$@"; do
        case $arg in
        --*=*) NORMALIZED_ARGS+=("${arg%%=*}" "${arg#*=}") ;;
        *) NORMALIZED_ARGS+=("$arg") ;;
        esac
    done
}

# Проверяет, что у опции есть значение. Вызывается до shift.
require_value() {
    [ "$2" -ge 2 ] || die "Option $1 requires a value"
}

# --- Общие проверки --------------------------------------------------------

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

validate_ip() {
    local ip=$1 octet
    [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || {
        log_error "Invalid IP address: $ip"
        return 1
    }
    # Диапазон октетов regexp не проверяет, поэтому проверяем отдельно.
    for octet in ${ip//./ }; do
        [ "$octet" -le 255 ] || {
            log_error "Invalid IP address: $ip"
            return 1
        }
    done
    return 0
}

validate_ip_list() {
    # Валидирует все переданные адреса. Отдельной функцией, а не через nameref:
    # bash в macOS — 3.2, там local -n не поддерживается.
    local ip
    for ip in "$@"; do
        validate_ip "$ip" || exit 1
    done
}

# --- Предикаты состояния нод ----------------------------------------------

# Insecure API отвечает только в maintenance mode: на настроенной ноде apid
# требует клиентский сертификат.
is_maintenance() {
    talosctl version --insecure --nodes "$1" >/dev/null 2>&1
}

is_configured() {
    talosctl --nodes "$1" version >/dev/null 2>&1
}

etcd_has_peer() {
    talosctl --nodes "$cluster_endpoint" etcd members 2>/dev/null |
        grep -q "://${1}:2380"
}

cluster_has_member() {
    talosctl --nodes "$cluster_endpoint" get members 2>/dev/null |
        grep -q "\"${1}\""
}

# Ждёт выполнения предиката вместо фиксированного sleep.
wait_until() {
    local desc=$1 timeout=$2
    shift 2
    local deadline=$(($(date +%s) + timeout))
    log_info "Waiting for: $desc"
    until "$@"; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            die "Timeout after ${timeout}s waiting for: $desc"
        fi
        sleep "$POLL_INTERVAL"
    done
    log_info "Ready: $desc"
}

# --- Работа с machine config ---------------------------------------------

node_talos_version() {
    talosctl --nodes "$1" version 2>/dev/null |
        awk '/^Server:/ {f=1} f && /Tag:/ {print $2; exit}'
}

extract_install_image() {
    # machine.install.image из файла конфига.
    local file=$1 line
    line=$(grep -nE '^[[:space:]]*install:[[:space:]]*$' "$file" | head -1 | cut -d: -f1)
    [ -n "$line" ] || return 1
    sed -n "${line},$((line + 12))p" "$file" |
        grep -E '^[[:space:]]*image:' | head -1 |
        sed 's/^[[:space:]]*image:[[:space:]]*//; s/[[:space:]]*#.*$//'
}

retag_image() {
    # Меняет тег образа на указанную версию. Образы, закреплённые по digest,
    # не трогаем — там тега нет.
    local image=$1 version=$2
    case "$image" in
    *@sha256:*)
        echo "$image"
        return 1
        ;;
    esac
    echo "${image%:*}:${version}"
}

find_node_by_role() {
    # Возвращает IPv4 первой ноды указанной роли (controlplane|worker).
    local role=$1
    talosctl --nodes "$cluster_endpoint" get members 2>/dev/null |
        awk -v r="$role" 'NR>1 && $7==r {print $NF; exit}' |
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

prepare_join_config() {
    # Снимает конфиг с живой ноды и готовит его для новых нод той же роли.
    # $1 — IP ноды-источника, $2 — путь результата.
    local source_ip=$1 out_file=$2
    local raw="${work_dir}/source-$(basename "$out_file")"
    local running_version live_image target_image

    log_info "Reading machine config from live node ${source_ip}"
    talosctl --nodes "$source_ip" get mc -o jsonpath='{.spec}' >"$raw" 2>/dev/null ||
        die "Failed to read machine config from ${source_ip}"
    [ -s "$raw" ] || die "Machine config read from ${source_ip} is empty"

    # Снятый конфиг содержит сетевые настройки самой ноды-источника. Если там
    # статический адрес, он уедет на все новые ноды и вызовет конфликт IP.
    if [ "$keep_network" = true ]; then
        log_warning "Keeping source node's network config: new nodes may claim ${source_ip}"
        cp "$raw" "$out_file"
    elif talosctl machineconfig patch "$raw" \
        --patch '[{"op":"remove","path":"/machine/network/interfaces"}]' \
        -o "$out_file" 2>/dev/null; then
        log_info "Dropped source node's static network config, new nodes will use DHCP"
    else
        cp "$raw" "$out_file"
        log_info "Source config has no static interfaces, nothing to drop"
    fi

    # install.image в конфиге может отставать от реально работающей версии:
    # talosctl upgrade это поле не переписывает.
    running_version=$(node_talos_version "$source_ip")
    live_image=$(extract_install_image "$out_file") || die "No machine.install.image in source config"

    if [ -n "$install_image" ]; then
        target_image=$install_image
    elif [ -n "$running_version" ]; then
        target_image=$(retag_image "$live_image" "$running_version") || {
            log_warning "Installer image is pinned by digest, leaving as is: ${live_image}"
            target_image=$live_image
        }
    else
        target_image=$live_image
    fi

    if [ "$target_image" != "$live_image" ]; then
        log_warning "Installer image in source config: ${live_image}"
        log_warning "Node ${source_ip} actually runs ${running_version}, using: ${target_image}"
        # sed по литералу: строка образа уникальна в пределах конфига.
        sed "s|${live_image}|${target_image}|" "$out_file" >"${out_file}.tmp"
        mv "${out_file}.tmp" "$out_file"
    else
        log_info "Installer image: ${target_image}"
    fi

    if [ -n "$patch_file" ]; then
        log_info "Applying extra patch: ${patch_file}"
        talosctl machineconfig patch "$out_file" --patch "@${patch_file}" -o "${out_file}.tmp" ||
            die "Failed to apply patch ${patch_file}"
        mv "${out_file}.tmp" "$out_file"
    fi

    talosctl validate -c "$out_file" -m metal >/dev/null ||
        die "Prepared config is not valid for metal mode"
    log_info "Config for new nodes prepared and validated"
}

apply_to_node() {
    # $1 — IP, $2 — файл конфига, $3 — человекочитаемая роль.
    local ip=$1 config=$2 role=$3
    # Insecure API отвечает только в maintenance mode, поэтому неудача здесь
    # означает либо уже настроенную ноду, либо недоступную.
    is_maintenance "$ip" ||
        die "Node ${ip} did not answer on the maintenance API. Either it is unreachable, or it is already configured — in the latter case wipe its disk and boot from ISO before applying a config."
    log_info "Applying ${role} config to ${ip}"
    talosctl apply-config --insecure --nodes "$ip" --file "$config"
}

# --- bootstrap ------------------------------------------------------------

cmd_bootstrap() {
    local cluster_name=$DEFAULT_CLUSTER_NAME
    local config_dir=$DEFAULT_CONFIG_DIR
    local kubernetes_version="" force=false
    local -a control_plane_ips=() worker_node_ips=()
    install_image=""
    timeout=$DEFAULT_TIMEOUT

    if [ $# -gt 0 ]; then
        normalize_long_args "$@"
        set -- "${NORMALIZED_ARGS[@]}"
    fi

    while [ $# -gt 0 ]; do
        case $1 in
        -c | --controlplane)
            require_value "$1" $#
            IFS=',' read -ra control_plane_ips <<<"$2"
            validate_ip_list "${control_plane_ips[@]}"
            shift 2
            ;;
        -w | --workers)
            require_value "$1" $#
            IFS=',' read -ra worker_node_ips <<<"$2"
            validate_ip_list "${worker_node_ips[@]}"
            shift 2
            ;;
        -n | --cluster-name)
            require_value "$1" $#
            cluster_name=$2
            shift 2
            ;;
        -i | --install-image)
            require_value "$1" $#
            install_image=$2
            shift 2
            ;;
        -k | --kubernetes-version)
            require_value "$1" $#
            kubernetes_version=$2
            shift 2
            ;;
        -d | --output-dir)
            require_value "$1" $#
            config_dir=$2
            shift 2
            ;;
        -T | --timeout)
            require_value "$1" $#
            timeout=$2
            shift 2
            ;;
        -f | --force)
            force=true
            shift
            ;;
        -h | --help) usage ;;
        *) die "Unknown option for 'bootstrap': $1" ;;
        esac
    done

    [ ${#control_plane_ips[@]} -gt 0 ] || die "At least one control-plane IP is required (-c)"

    local first_cp=${control_plane_ips[0]}
    local talosconfig="${config_dir}/talosconfig"

    if [ -f "${config_dir}/controlplane.yaml" ] && [ "$force" != true ]; then
        die "${config_dir}/controlplane.yaml already exists. Refusing to regenerate secrets — that would produce a PKI incompatible with the running cluster. Use -f to overwrite, or 'join' to add nodes."
    fi

    # Главная защита: bootstrap допустим только по нодам в maintenance mode.
    log_info "Checking that all target nodes are in maintenance mode"
    local ip
    local -a all_ips=("${control_plane_ips[@]}")
    if [ ${#worker_node_ips[@]} -gt 0 ]; then
        all_ips=("${all_ips[@]}" "${worker_node_ips[@]}")
    fi
    for ip in "${all_ips[@]}"; do
        is_maintenance "$ip" ||
            die "Node ${ip} is not in maintenance mode — it looks already configured. Bootstrapping it would destroy the existing cluster. Use 'join' to add nodes."
    done

    log_info "Generating cluster configuration in ${config_dir}"
    local -a gen_args=(gen config "$cluster_name" "https://${first_cp}:6443" --output-dir "$config_dir")
    [ -n "$install_image" ] && gen_args+=(--install-image "$install_image")
    [ -n "$kubernetes_version" ] && gen_args+=(--kubernetes-version "$kubernetes_version")
    [ "$force" = true ] && gen_args+=(--force)
    talosctl "${gen_args[@]}"

    for ip in "${control_plane_ips[@]}"; do
        log_info "Applying control-plane config to ${ip}"
        talosctl apply-config --insecure --nodes "$ip" --file "${config_dir}/controlplane.yaml"
    done

    talosctl config endpoint "$first_cp" --talosconfig "$talosconfig"
    talosctl config node "$first_cp" --talosconfig "$talosconfig"
    export TALOSCONFIG=$talosconfig

    wait_until "control-plane ${first_cp} API to come up" "$timeout" is_configured "$first_cp"

    # Bootstrap выполняется РОВНО ОДИН РАЗ и только на первой CP-ноде.
    log_info "Bootstrapping etcd on ${first_cp}"
    talosctl bootstrap --nodes "$first_cp"

    cluster_endpoint=$first_cp
    wait_until "etcd member ${first_cp} to appear" "$timeout" etcd_has_peer "$first_cp"

    if [ ${#control_plane_ips[@]} -gt 1 ]; then
        for ip in "${control_plane_ips[@]:1}"; do
            wait_until "control-plane ${ip} to join etcd" "$timeout" etcd_has_peer "$ip"
        done
    fi

    if [ ${#worker_node_ips[@]} -gt 0 ]; then
        for ip in "${worker_node_ips[@]}"; do
            log_info "Applying worker config to ${ip}"
            talosctl apply-config --insecure --nodes "$ip" --file "${config_dir}/worker.yaml"
        done
        for ip in "${worker_node_ips[@]}"; do
            wait_until "worker ${ip} to join the cluster" "$timeout" cluster_has_member "$ip"
        done
    fi

    log_info "Fetching kubeconfig"
    talosctl kubeconfig . --nodes "$first_cp"

    summary "$first_cp"
}

# --- join -----------------------------------------------------------------

cmd_join() {
    local talosconfig="${TALOSCONFIG:-}"
    local -a new_cp_ips=() new_worker_ips=()
    cluster_endpoint=""
    install_image=""
    patch_file=""
    keep_network=false
    timeout=$DEFAULT_TIMEOUT

    if [ $# -gt 0 ]; then
        normalize_long_args "$@"
        set -- "${NORMALIZED_ARGS[@]}"
    fi

    while [ $# -gt 0 ]; do
        case $1 in
        -e | --endpoint)
            require_value "$1" $#
            cluster_endpoint=$2
            shift 2
            ;;
        -c | --controlplane)
            require_value "$1" $#
            IFS=',' read -ra new_cp_ips <<<"$2"
            validate_ip_list "${new_cp_ips[@]}"
            shift 2
            ;;
        -w | --workers)
            require_value "$1" $#
            IFS=',' read -ra new_worker_ips <<<"$2"
            validate_ip_list "${new_worker_ips[@]}"
            shift 2
            ;;
        -i | --install-image)
            require_value "$1" $#
            install_image=$2
            shift 2
            ;;
        -p | --patch)
            require_value "$1" $#
            patch_file=$2
            shift 2
            ;;
        -t | --talosconfig)
            require_value "$1" $#
            talosconfig=$2
            shift 2
            ;;
        -T | --timeout)
            require_value "$1" $#
            timeout=$2
            shift 2
            ;;
        -K | --keep-network)
            keep_network=true
            shift
            ;;
        -h | --help) usage ;;
        *) die "Unknown option for 'join': $1" ;;
        esac
    done

    [ -n "$cluster_endpoint" ] || die "IP of an existing cluster node is required (-e)"
    validate_ip "$cluster_endpoint" || exit 1
    [ $((${#new_cp_ips[@]} + ${#new_worker_ips[@]})) -gt 0 ] ||
        die "Nothing to add: specify -c and/or -w"
    [ -n "$patch_file" ] && [ ! -f "$patch_file" ] && die "Patch file not found: ${patch_file}"

    [ -n "$talosconfig" ] || die "talosconfig is required for join: pass -t or set TALOSCONFIG"
    [ -f "$talosconfig" ] || die "talosconfig not found: ${talosconfig}"
    export TALOSCONFIG=$talosconfig

    is_configured "$cluster_endpoint" ||
        die "Cannot reach ${cluster_endpoint} with the provided talosconfig"

    # Работающий кластер обязан иметь хотя бы одного члена etcd. Если его нет,
    # кластер не инициализирован и нужен bootstrap, а не join.
    talosctl --nodes "$cluster_endpoint" etcd members >/dev/null 2>&1 ||
        die "No etcd cluster found at ${cluster_endpoint}. Use 'bootstrap' for a new cluster."

    local members_before
    members_before=$(talosctl --nodes "$cluster_endpoint" etcd members 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    log_info "Existing cluster has ${members_before} etcd member(s)"

    work_dir=$(mktemp -d)
    chmod 700 "$work_dir"

    local ip
    if [ ${#new_cp_ips[@]} -gt 0 ]; then
        local cp_source
        cp_source=$(find_node_by_role controlplane)
        [ -n "$cp_source" ] || die "No control-plane node found in the cluster to copy config from"

        local cp_config="${work_dir}/controlplane.yaml"
        prepare_join_config "$cp_source" "$cp_config"

        # Ноды добавляются строго по одной. При переходе с 1 на 2 члена кворум
        # растёт до 2: если новая нода не поднимется, кластер потеряет запись.
        for ip in "${new_cp_ips[@]}"; do
            apply_to_node "$ip" "$cp_config" "control-plane"
            wait_until "control-plane ${ip} to become an etcd member" "$timeout" etcd_has_peer "$ip"
            log_info "Control-plane ${ip} joined"
        done
    fi

    if [ ${#new_worker_ips[@]} -gt 0 ]; then
        # Конфиг воркера нельзя получить из конфига control-plane: у них разный
        # machine.type и разный набор секций.
        local worker_source
        worker_source=$(find_node_by_role worker)
        [ -n "$worker_source" ] ||
            die "No worker node in the cluster to copy config from. Generate a worker config from the cluster secrets manually."

        local worker_config="${work_dir}/worker.yaml"
        prepare_join_config "$worker_source" "$worker_config"

        for ip in "${new_worker_ips[@]}"; do
            apply_to_node "$ip" "$worker_config" "worker"
        done
        for ip in "${new_worker_ips[@]}"; do
            wait_until "worker ${ip} to join the cluster" "$timeout" cluster_has_member "$ip"
        done
    fi

    # bootstrap здесь не вызывается ни при каких условиях: кластер уже
    # инициализирован, повторный bootstrap разрушает etcd.
    summary "$cluster_endpoint"
}

summary() {
    local endpoint=$1
    echo
    log_info "Done. Cluster state:"
    talosctl --nodes "$endpoint" etcd members || true
    echo
    talosctl --nodes "$endpoint" get members || true
}

# --- Точка входа ----------------------------------------------------------

main() {
    require_cmd talosctl
    [ $# -gt 0 ] || usage

    local command=$1
    shift

    case $command in
    bootstrap) cmd_bootstrap "$@" ;;
    join) cmd_join "$@" ;;
    -h | help | --help) usage ;;
    *) die "Unknown command: ${command}. Expected 'bootstrap' or 'join'." ;;
    esac
}

main "$@"
