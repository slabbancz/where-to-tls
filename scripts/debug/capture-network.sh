#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

fatal() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: sudo ./scripts/debug/{client,server}.sh (--peer-ip <IPv4> | --peer-ips <IPv4,...>) [options]

Run on the client VMSS or standalone server VMSS, not on the jumpbox.
Client peer: the actual destination dialed by k6 (usually the private LB).
Server peer: the client source address visible at the workload.

  --port <port>             Destination port on client / local port on server (8443).
  --peer-ips <IPv4,...>     Comma-separated peer addresses. Use this on the
                            server to capture a client source-IP pool.
  --duration <seconds>      Observation window including post-load drain (180; max 3600).
  --interval <seconds>      Socket and host sampling interval (1; max 60).
  --interface <name>        tcpdump interface (any); optionally select the VM NIC.
  --capture-mode <mode>     control (default): SYN/FIN/RST, snaplen 96.
                            full: all matching TCP packets, snaplen 262144.
                            Full mode requires an explicit --packet-limit.
  --packet-limit <count>    Stop packet capture after this many matching packets (10000000).
                            Socket/host sampling continues; truncation is reported.
  --pid <host-pid>          Optional workload PID for FD, thread, I/O and CPU evidence.
                            Use the host PID, not the PID inside a container.
  --name-suffix <label>     Safe label appended to the default output directory name.
                            For example: wtt-client-flat-200-<UTC timestamp>.
  --output <directory>     New directory; never overwrite existing evidence.
  --help                   Print help.

Requires root, bash, iproute2 (ip/ss), tcpdump, procps (ps), awk and coreutils.
Does not install packages, create traffic, change sysctls, or restart anything.
Wait for WTT_CAPTURE_READY before starting the workload in another terminal.
Ctrl-C stops only this collector and preserves partial evidence (exit 130).
EOF
}

role="${1:-}"
[[ "${role}" == client || "${role}" == server ]] || fatal "role must be client or server"
shift
peer_ip=
peer_ips_csv=
port=8443
duration=180
interval=1
interface=any
capture_mode=control
packet_limit=10000000
packet_limit_explicit=false
pid=
output=
name_suffix=
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --peer-ip|--peer-ips|--port|--duration|--interval|--interface|--capture-mode|--packet-limit|--pid|--name-suffix|--output)
      (($# >= 2)) && [[ -n "$2" ]] || fatal "$1 requires a value"
      case "$1" in
        --peer-ip) peer_ip="$2" ;;
        --peer-ips) peer_ips_csv="$2" ;;
        --port) port="$2" ;;
        --duration) duration="$2" ;;
        --interval) interval="$2" ;;
        --interface) interface="$2" ;;
        --capture-mode) capture_mode="$2" ;;
        --packet-limit) packet_limit="$2"; packet_limit_explicit=true ;;
        --pid) pid="$2" ;;
        --name-suffix) name_suffix="$2" ;;
        --output) output="$2" ;;
      esac
      shift 2
      ;;
    *) fatal "unknown option: $1" ;;
  esac
done

[[ -z "${peer_ip}" || -z "${peer_ips_csv}" ]] ||
  fatal "--peer-ip and --peer-ips cannot be combined"
[[ -n "${peer_ip}${peer_ips_csv}" ]] ||
  fatal "one of --peer-ip or --peer-ips is required"
if [[ -n "${peer_ip}" ]]; then
  peer_ips_csv="${peer_ip}"
fi
IFS=, read -r -a peer_ips <<<"${peer_ips_csv}"
((${#peer_ips[@]} > 0 && ${#peer_ips[@]} <= 32)) ||
  fatal "--peer-ips must contain from one through 32 IPv4 addresses"
declare -A seen_peer_ips=()
for index in "${!peer_ips[@]}"; do
  peer="${peer_ips[index]}"
  [[ "${peer}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
    fatal "--peer-ips contains an invalid IPv4 address"
  IFS=. read -r -a octets <<<"${peer}"
  for octet in "${octets[@]}"; do
    ((10#${octet} <= 255)) ||
      fatal "--peer-ips contains an invalid IPv4 address"
  done
  printf -v peer '%d.%d.%d.%d' \
    "$((10#${octets[0]}))" "$((10#${octets[1]}))" \
    "$((10#${octets[2]}))" "$((10#${octets[3]}))"
  [[ -z "${seen_peer_ips[${peer}]:-}" ]] ||
    fatal "--peer-ips contains a duplicate IPv4 address"
  seen_peer_ips["${peer}"]=1
  peer_ips[index]="${peer}"
done
peer_ips_csv=$(IFS=,; printf '%s' "${peer_ips[*]}")

positive_integer() {
  [[ "$2" =~ ^[1-9][0-9]{0,9}$ ]] && (($2 <= $3)) ||
    fatal "$1 must be an integer from 1 through $3 (no leading zeros)"
}
positive_integer --port "${port}" 65535
positive_integer --duration "${duration}" 3600
positive_integer --interval "${interval}" 60
positive_integer --packet-limit "${packet_limit}" 20000000
[[ "${capture_mode}" == control || "${capture_mode}" == full ]] ||
  fatal "--capture-mode must be control or full"
[[ "${capture_mode}" != full || "${packet_limit_explicit}" == true ]] ||
  fatal "--capture-mode full requires an explicit --packet-limit; full packets can consume much more disk"
[[ -z "${pid}" ]] || positive_integer --pid "${pid}" 2147483647
[[ -z "${name_suffix}" || "${name_suffix}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
  fatal "--name-suffix must be 1-64 ASCII letters, digits, dots, underscores, or hyphens; it cannot begin with punctuation"
((EUID == 0)) || fatal "run as root on the target node"
for tool in ss ip tcpdump awk ps date sleep mkdir mktemp cp cat wc readlink getconf hostname find grep tee uname rm rmdir; do
  command -v "${tool}" >/dev/null || fatal "required tool missing: ${tool}"
done

if [[ -n "${pid}" ]]; then
  [[ -r "/proc/${pid}/stat" ]] || fatal "PID ${pid} is not running"
  # Strip comm (which may contain spaces) before locating field 22: starttime.
  pid_start=$(awk '{sub(/^.*\) /, ""); print $20}' "/proc/${pid}/stat")
fi
if [[ -z "${output}" ]]; then
  output="/var/tmp/wtt-${role}${name_suffix:+-${name_suffix}}-$(date -u +%Y%m%dT%H%M%SZ)"
fi
umask 077
mkdir -- "${output}" || fatal "cannot create new output directory: ${output}"
output=$(readlink -f "${output}")
scratch=$(mktemp -d "${output}/.scratch.XXXXXX")
: > "${output}/tcpdump.log"
capture_pid=
capture_done=false
capture_capped=false
cleanup() {
  local status=$?
  local packets dropped
  trap - EXIT
  if [[ -n "${capture_pid}" ]]; then
    if kill -0 "${capture_pid}" 2>/dev/null; then
      kill -INT "${capture_pid}" 2>/dev/null || printf 'WARN: tcpdump already exited\n' >&2
    fi
    if wait "${capture_pid}"; then
      :
    else
      printf 'ERROR: tcpdump exited unsuccessfully; see %s/tcpdump.log\n' "${output}" >&2
      ((status != 0)) || status=1
    fi
  fi
  packets=$(awk '/packets captured$/ {print $1}' "${output}/tcpdump.log")
  dropped=$(awk '/packets dropped by kernel$/ {print $1}' "${output}/tcpdump.log")
  if [[ -n "${packets}" ]] && ((packets >= packet_limit)); then capture_capped=true; fi
  if [[ "${capture_capped}" == true || "${dropped:-0}" != 0 ]]; then
    printf 'WARN: packet evidence incomplete: capped=%s kernel_drops=%s\n' "${capture_capped}" "${dropped:-unknown}" >&2
  fi
  printf 'packets_captured=%s\npackets_dropped_by_kernel=%s\npacket_limit_reached=%s\n' \
    "${packets:-unknown}" "${dropped:-unknown}" "${capture_capped}" >> "${output}/manifest.txt"
  rm -f -- "${scratch}/sockets" "${scratch}/listeners"
  rmdir -- "${scratch}"
  printf 'exit_status=%s\nfinished_utc=%s\n' "${status}" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >> "${output}/manifest.txt"
  printf 'WTT_CAPTURE_OUTPUT=%s\n' "${output}" >&2
  exit "${status}"
}
trap cleanup EXIT
trap 'printf "ERROR: collector failed at line %s; evidence preserved in %s\n" "${LINENO}" "${output}" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "${role}" == client ]]; then
  socket_direction="dst"
  socket_port="dport"
else
  socket_direction="dst"
  socket_port="sport"
fi
socket_peers=
bpf_peers=
for peer in "${peer_ips[@]}"; do
  socket_peers+="${socket_direction} ${peer} or "
  bpf_peers+="host ${peer} or "
done
socket_peers="${socket_peers% or }"
bpf_peers="${bpf_peers% or }"
socket_filter="( ${socket_peers} ) and ${socket_port} = :${port}"
bpf="ip and (${bpf_peers}) and tcp port ${port}"
snaplen=262144
packet_file=full.pcap
if [[ "${capture_mode}" == control ]]; then
  bpf+=" and (tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0)"
  snaplen=96
  packet_file=control.pcap
else
  printf 'WARN: full TCP payload capture enabled; keep this evidence private and monitor disk usage\n' >&2
fi
{
  printf 'role=%s\nhostname=%s\nstarted_utc=%s\n' "${role}" "$(hostname)" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
  printf 'peer_ips=%s\nport=%s\nduration_seconds=%s\ninterval_seconds=%s\n' "${peer_ips_csv}" "${port}" "${duration}" "${interval}"
  printf 'interface=%s\npacket_limit=%s\nsnaplen=%s\npid=%s\nname_suffix=%s\n' \
    "${interface}" "${packet_limit}" "${snaplen}" "${pid:-none}" "${name_suffix:-none}"
  printf 'capture_mode=%s\npacket_file=%s\n' "${capture_mode}" "${packet_file}"
  printf 'ss_filter=%s\nbpf=%s\nclock_ticks_per_second=%s\n' "${socket_filter}" "${bpf}" "$(getconf CLK_TCK)"
} > "${output}/manifest.txt"
{
  uname -a
  ip -brief address
  for peer in "${peer_ips[@]}"; do
    ip route get "${peer}"
  done
  for key in ip_local_port_range ip_local_reserved_ports tcp_tw_reuse tcp_fin_timeout tcp_max_tw_buckets tcp_max_syn_backlog tcp_syn_retries tcp_synack_retries; do
    printf 'net.ipv4.%s=' "${key}"
    cat "/proc/sys/net/ipv4/${key}"
  done
  printf 'net.core.somaxconn='; cat /proc/sys/net/core/somaxconn
  printf 'fs.file-max='; cat /proc/sys/fs/file-max
} > "${output}/host-config.txt"
printf 'utc\tstate\tcount\trecv_queue_bytes\tsend_queue_bytes\n' > "${output}/socket-states.tsv"
printf 'utc\tconnections\tunique_local_ports\n' > "${output}/ports.tsv"
printf 'utc\tpid\tfd_count\n' > "${output}/process-fds.tsv"

if [[ -n "${pid}" ]]; then
  cp "/proc/${pid}/limits" "${output}/process-limits.txt"
  cp "/proc/${pid}/cgroup" "${output}/process-cgroup.txt"
  cgroup_relative=$(awk -F: '$1 == "0" {print $3}' "/proc/${pid}/cgroup")
  cgroup_dir=
  if [[ -n "${cgroup_relative}" && -d "/sys/fs/cgroup${cgroup_relative}" ]]; then
    cgroup_dir="/sys/fs/cgroup${cgroup_relative}"
  fi
fi

sample() {
  local now stat start fd_count
  now=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
  ss -H -t -a -n -o "${socket_filter}" > "${scratch}/sockets"
  [[ -e "${output}/sockets-first.txt" ]] || cp "${scratch}/sockets" "${output}/sockets-first.txt"
  cp "${scratch}/sockets" "${output}/sockets-last.txt"
  awk -v now="${now}" '{
    count[$1]++; recv[$1]+=$2; send[$1]+=$3
  } END {
    if (NR == 0) printf "%s\tNONE\t0\t0\t0\n",now
    for (s in count) printf "%s\t%s\t%d\t%.0f\t%.0f\n",now,s,count[s],recv[s],send[s]
  }' "${scratch}/sockets" >> "${output}/socket-states.tsv"
  awk -v now="${now}" '{p=$4; sub(/^.*:/,"",p); ports[p]=1} END {
    for (p in ports) n++
    printf "%s\t%d\t%d\n",now,NR,n
  }' "${scratch}/sockets" >> "${output}/ports.tsv"
  {
    printf '\nUTC=%s\n' "${now}"
    ps -e -o pid,ppid,nlwp,pcpu,rss,etimes,comm
    for file in stat meminfo loadavg net/sockstat net/sockstat6 net/snmp net/netstat net/dev sys/fs/file-nr; do
      printf '\nFILE=/proc/%s\n' "${file}"
      cat "/proc/${file}"
    done
  } >> "${output}/host-samples.txt"
  if [[ "${role}" == server ]]; then
    ss -H -l -t -n "sport = :${port}" > "${scratch}/listeners"
    printf '\nUTC=%s\n' "${now}" >> "${output}/listener-queues.txt"
    cat "${scratch}/listeners" >> "${output}/listener-queues.txt"
  fi
  if [[ -n "${pid}" ]]; then
    if [[ -r "/proc/${pid}/stat" ]]; then
      stat=$(cat "/proc/${pid}/stat")
      start=$(awk '{sub(/^.*\) /, ""); print $20}' <<<"${stat}")
    else
      start=
    fi
    if [[ "${start}" != "${pid_start}" ]]; then
      printf 'UTC=%s PID=%s exited or was reused; stopping process samples\n' "${now}" "${pid}" | tee -a "${output}/process-samples.txt" >&2
      pid=
      return
    fi
    {
      printf '\nUTC=%s\nSTAT=%s\n' "${now}" "${stat}"
      cat "/proc/${pid}/status" "/proc/${pid}/io" "/proc/${pid}/schedstat"
      ps -p "${pid}" -o pid,ppid,nlwp,pcpu,pmem,etimes,comm
      if [[ -n "${cgroup_dir}" ]]; then
        for file in cpu.max cpu.stat memory.max memory.current memory.events pids.max pids.current; do
          if [[ -r "${cgroup_dir}/${file}" ]]; then
            printf '\nCGROUP_FILE=%s\n' "${file}"
            cat "${cgroup_dir}/${file}"
          fi
        done
      fi
    } >> "${output}/process-samples.txt"
    fd_count=$(find "/proc/${pid}/fd" -mindepth 1 -maxdepth 1 -type l -printf '.' | wc -c)
    printf '%s\t%s\t%s\n' "${now}" "${pid}" "${fd_count}" >> "${output}/process-fds.tsv"
  fi
}

# Keep the writer in the root-only evidence directory across distro defaults.
tcpdump -Z root -i "${interface}" -nn -U -s "${snaplen}" -c "${packet_limit}" \
  -w "${output}/${packet_file}" "${bpf}" 2>"${output}/tcpdump.log" &
capture_pid=$!
ready=false
for ((attempt=0; attempt<50; attempt++)); do
  if grep -q 'listening on' "${output}/tcpdump.log"; then ready=true; break; fi
  kill -0 "${capture_pid}" 2>/dev/null || { cat "${output}/tcpdump.log" >&2; fatal "tcpdump failed to start"; }
  sleep 0.1
done
[[ "${ready}" == true ]] || fatal "tcpdump did not become ready within 5 seconds"
printf 'WTT_CAPTURE_READY role=%s utc=%s output=%s\n' "${role}" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" "${output}"
deadline=$((SECONDS + duration))
while :; do
  sample
  if [[ "${capture_done}" == false ]] && ! kill -0 "${capture_pid}" 2>/dev/null; then
    if wait "${capture_pid}"; then
      capture_pid=
      capture_done=true
      capture_capped=true
      printf 'WARN: packet limit reached; packet evidence is incomplete, socket sampling continues\n' | tee -a "${output}/capture-warnings.txt" >&2
    else
      capture_pid=
      fatal "tcpdump failed during capture; see tcpdump.log"
    fi
  fi
  remaining=$((deadline - SECONDS))
  ((remaining > 0)) || break
  pause="${interval}"
  ((pause <= remaining)) || pause="${remaining}"
  sleep "${pause}"
done
printf 'sampling_complete=true\n' >> "${output}/manifest.txt"
