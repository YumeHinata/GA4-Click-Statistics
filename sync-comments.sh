
#!/usr/bin/env bash
set -Eeuo pipefail

# ===== 配置 =====
BLOG_ORIGIN="${BLOG_ORIGIN:-https://www.yumehinata.com}"
BLOG_ORIGIN="${BLOG_ORIGIN%/}"

SITEMAP_URL="${SITEMAP_URL:-${BLOG_ORIGIN}/sitemap-index.xml}"
TWIKOO_ENV_ID="${TWIKOO_ENV_ID:-https://twikoo.yumehinata.com/}"
TWIKOO_INCLUDE_REPLY="${TWIKOO_INCLUDE_REPLY:-true}"
BATCH_SIZE="${BATCH_SIZE:-50}"

# ===== 检查依赖 =====
for cmd in curl jq xmlstarlet; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: 缺少依赖 $cmd"
        exit 1
    fi
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

declare -A VISITED=()
declare -A ARTICLES=()
declare -A PATH_TO_KEY=()
declare -A COUNTS=()

SITEMAP_INDEX=0

# 规范化 URL 路径，但保留中文 URL 的编码形式。
normalize_path() {
    local path="$1"

    if [[ "$path" == http://* || "$path" == https://* ]]; then
        path="${path#*://}"
        path="/${path#*/}"
    fi

    path="${path%%\?*}"
    path="${path%%\#*}"
    path="${path%/index.html}"
    path="${path%/index.htm}"

    while [[ "$path" == */ && "$path" != "/" ]]; do
        path="${path%/}"
    done

    printf '%s' "${path:-/}"
}

# 将百分号编码还原，仅用于匹配，不用于输出 JSON 键。
url_decode() {
    local value
    value="$(printf '%s' "$1" |
        sed -E 's/%([[:xdigit:]]{2})/\\x\1/g')"
    printf '%b' "$value"
}

# 递归读取 Sitemap。
fetch_sitemap() {
    local sitemap_url="$1"
    local file root loc path decoded
    local -a locations=()

    if [[ -n "${VISITED[$sitemap_url]+x}" ]]; then
        return
    fi
    VISITED["$sitemap_url"]=1

    SITEMAP_INDEX=$((SITEMAP_INDEX + 1))
    file="$TMP_DIR/sitemap-${SITEMAP_INDEX}.xml"

    echo "读取 Sitemap: $sitemap_url"

    curl -fsSL --retry 3 --max-time 30 \
        "$sitemap_url" -o "$file"

    root="$(xmlstarlet sel -t -v 'local-name(/*)' "$file")"

    case "$root" in
        sitemapindex)
            mapfile -t locations < <(
                xmlstarlet sel \
                    -t -m '/*[local-name()="sitemapindex"]/*[local-name()="sitemap"]/*[local-name()="loc"]' \
                    -v . -n "$file"
            )

            for loc in "${locations[@]}"; do
                fetch_sitemap "$loc"
            done
            ;;

        urlset)
            mapfile -t locations < <(
                xmlstarlet sel \
                    -t -m '/*[local-name()="urlset"]/*[local-name()="url"]/*[local-name()="loc"]' \
                    -v . -n "$file"
            )

            for loc in "${locations[@]}"; do
                # 只统计本博客 /posts/ 下的文章。
                [[ "$loc" == "$BLOG_ORIGIN"/posts/* ]] || continue

                path="$(normalize_path "$loc")"
                [[ "$path" == /posts/* ]] || continue

                ARTICLES["$path"]=1
                PATH_TO_KEY["$path"]="$path"

                # 同时建立解码路径别名，避免中文编码形式不同而匹配失败。
                decoded="$(url_decode "$path")"
                PATH_TO_KEY["$decoded"]="$path"
            done
            ;;

        *)
            echo "Error: 无法识别 Sitemap 格式：$sitemap_url" >&2
            return 1
            ;;
    esac
}

echo "正在读取文章列表..."
fetch_sitemap "$SITEMAP_URL"

if (( ${#ARTICLES[@]} == 0 )); then
    echo "Error: Sitemap 中没有找到 /posts/ 文章。" >&2
    exit 1
fi

mapfile -t ARTICLE_LIST < <(
    printf '%s\n' "${!ARTICLES[@]}" | LC_ALL=C sort
)

echo "共找到 ${#ARTICLE_LIST[@]} 篇文章。"

# 初始化所有文章的评论数。
for path in "${ARTICLE_LIST[@]}"; do
    COUNTS["$path"]=0
done

# ===== 批量调用 Twikoo =====
for ((i = 0; i < ${#ARTICLE_LIST[@]}; i += BATCH_SIZE)); do
    batch=("${ARTICLE_LIST[@]:i:BATCH_SIZE}")

    urls_json="$(
        printf '%s\n' "${batch[@]}" |
            jq -R . | jq -s .
    )"

    payload="$(
        jq -n \
            --arg envId "$TWIKOO_ENV_ID" \
            --argjson urls "$urls_json" \
            --argjson includeReply "$TWIKOO_INCLUDE_REPLY" \
            '{
                accessToken: null,
                event: "GET_COMMENTS_COUNT",
                envId: $envId,
                urls: $urls,
                includeReply: $includeReply
            }'
    )"

    echo "请求评论数：$((i + 1)) - $((i + ${#batch[@]})) / ${#ARTICLE_LIST[@]}"

    response="$(
        curl -fsS --retry 2 --max-time 60 \
            -X POST "$TWIKOO_ENV_ID" \
            -H 'Content-Type: application/json' \
            --data-binary "$payload"
    )"

    if ! jq -e '.result.data | type == "array"' \
        >/dev/null 2>&1 <<<"$response"; then
        echo "Error: Twikoo API 返回格式异常：" >&2
        jq . <<<"$response" >&2 || printf '%s\n' "$response" >&2
        exit 1
    fi

    declare -A BATCH_SEEN=()

    while IFS= read -r item; do
        item_url="$(jq -r '.url // empty' <<<"$item")"
        count="$(jq -r '.count // empty' <<<"$item")"

        [[ -n "$item_url" ]] || {
            echo "Error: Twikoo 返回了缺少 url 的记录。" >&2
            exit 1
        }

        [[ "$count" =~ ^[0-9]+$ ]] || {
            echo "Error: 无效的评论数：$item_url => $count" >&2
            exit 1
        }

        normalized="$(normalize_path "$item_url")"
        key="${PATH_TO_KEY[$normalized]-}"

        if [[ -z "$key" ]]; then
            decoded="$(url_decode "$normalized")"
            key="${PATH_TO_KEY[$decoded]-}"
        fi

        if [[ -z "$key" ]]; then
            echo "Error: 无法匹配 Twikoo 返回的文章路径：$item_url" >&2
            exit 1
        fi

        COUNTS["$key"]="$count"
        BATCH_SEEN["$key"]=1
    done < <(jq -c '.result.data[]' <<<"$response")

    # API 缺少文章记录时直接报错，避免把缺失数据误认为 0。
    for path in "${batch[@]}"; do
        if [[ -z "${BATCH_SEEN[$path]+x}" ]]; then
            echo "Error: Twikoo 未返回文章评论数：$path" >&2
            exit 1
        fi
    done

    unset BATCH_SEEN
done

# ===== 输出 JSON =====
mkdir -p data

{
    for path in "${ARTICLE_LIST[@]}"; do
        printf '%s\t%s\n' "$path" "${COUNTS[$path]}"
    done
} | jq -Rn '
    reduce inputs as $line
        ({};
         ($line | split("\t")) as $item
         | .[$item[0]] = ($item[1] | tonumber))
' > "$TMP_DIR/comments.json"

jq -S . "$TMP_DIR/comments.json" > "$TMP_DIR/comments.sorted.json"
mv "$TMP_DIR/comments.sorted.json" data/comments.json

echo "评论数同步成功！共 ${#ARTICLE_LIST[@]} 篇文章。"
echo "已写入 data/comments.json"
