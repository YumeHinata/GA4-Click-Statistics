#!/bin/bash

# 1. 检查依赖工具
if ! command -v jq &> /dev/null || ! command -v curl &> /dev/null; then
    echo "Error: jq or curl is not installed."
    exit 1
fi

# 2. 通过 Refresh Token 获取当次有效的 Access Token
# 这里的 CLIENT_ID, CLIENT_SECRET, REFRESH_TOKEN 都作为 GitHub Secrets 传入
echo "正在获取 Google Access Token..."
ACCESS_TOKEN=$(curl -s -X POST https://oauth2.googleapis.com/token \
  -d "client_id=${GA_CLIENT_ID}" \
  -d "client_secret=${GA_CLIENT_SECRET}" \
  -d "refresh_token=${GA_REFRESH_TOKEN}" \
  -d "grant_type=refresh_token" | jq -r '.access_token')

if [ "${ACCESS_TOKEN}" == "null" ] || [ -z "${ACCESS_TOKEN}" ]; then
    echo "获取 Access Token 失败，请检查密钥设置！"
    exit 1
fi

# 3. 请求 GA4 Data API 获取阅读量数据
echo "正在从 GA4 拉取阅读量数据..."
PAYLOAD='{
  "dateRanges": [{"startDate": "2020-01-01", "endDate": "today"}],
  "dimensions": [{"name": "pagePath"}],
  "metrics": [{"name": "screenPageViews"}]
}'

# 创建数据存放目录
mkdir -p data

# 4. 调用 API 并使用 jq 直接将结果清洗为 {"/path": 123} 的精简格式
curl -s -X POST "https://analyticsdata.googleapis.com/v1beta/properties/${GA_PROPERTY_ID}:runReport" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}" | jq '
    .rows
    | map({

        path: (.dimensionValues[0].value 
               | sub("^.*/posts/"; "/posts/") 
               | sub("index.html$"; "") 
               | sub("/$"; "")),
        views: (.metricValues[0].value | tonumber)
      })

    | map(select(.path | startswith("/posts/")))

    | group_by(.path)
    | map({(.[0].path): (map(.views) | add)})
    | add
  ' > data/views.json

echo "数据同步成功！已写入 data/views.json"