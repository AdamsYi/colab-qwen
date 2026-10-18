"""对话接口前置代理：去掉工具 JSON Schema 里的长度/数量/范围约束再转给 Studio。

llama.cpp 会把工具 schema 编译成约束语法，maxLength 等约束展开后规则数超限，
整次请求直接失败（"failed to parse grammar"）。这些约束只影响生成约束，去掉无副作用。
"""
import json
import os

import httpx

UPSTREAM = os.environ.get("SANITIZER_UPSTREAM", "http://127.0.0.1:9001")
STRIP = {
    "maxLength", "minLength", "maxItems", "minItems", "maximum", "minimum",
    "exclusiveMaximum", "exclusiveMinimum", "pattern", "maxProperties",
    "minProperties", "multipleOf", "uniqueItems",
}
HOP = {"host", "content-length", "connection", "transfer-encoding", "keep-alive"}

client = httpx.AsyncClient(base_url=UPSTREAM, timeout=httpx.Timeout(3600, connect=30))


def strip(node, in_properties=False):
    if isinstance(node, dict):
        if in_properties:  # 键是参数名（可能就叫 pattern），值才是 schema
            return {k: strip(v) for k, v in node.items()}
        out = {}
        for k, v in node.items():
            if k in STRIP and not isinstance(v, dict):
                continue
            out[k] = strip(v, in_properties=(k == "properties" and isinstance(v, dict)))
        return out
    if isinstance(node, list):
        return [strip(x) for x in node]
    return node


async def app(scope, receive, send):
    if scope["type"] != "http":
        return
    body = b""
    while True:
        msg = await receive()
        body += msg.get("body", b"")
        if not msg.get("more_body"):
            break
    if body:
        try:
            data = json.loads(body)
            if isinstance(data, dict) and data.get("tools"):
                data["tools"] = strip(data["tools"])
                body = json.dumps(data, ensure_ascii=False).encode()
        except ValueError:
            pass
    headers = [(k.decode(), v.decode()) for k, v in scope["headers"] if k.decode().lower() not in HOP]
    headers.append(("host", UPSTREAM.split("://", 1)[1]))
    path = scope["path"] + (("?" + scope["query_string"].decode()) if scope["query_string"] else "")
    req = client.build_request(scope["method"], path, headers=headers, content=body)
    resp = await client.send(req, stream=True)
    try:
        await send({
            "type": "http.response.start",
            "status": resp.status_code,
            "headers": [(k.encode(), v.encode()) for k, v in resp.headers.items() if k.lower() not in HOP],
        })
        async for chunk in resp.aiter_raw():
            await send({"type": "http.response.body", "body": chunk, "more_body": True})
        await send({"type": "http.response.body", "body": b""})
    finally:
        await resp.aclose()
