# WeChat publish relay (Tokyo VPS)

A tiny always-on HTTP service that publishes 公众号 drafts **synchronously** from the
VPS whose IP (`66.42.45.128`) is whitelisted on the WeChat account. The Cloudflare
Function (`jianshuo.dev/files/api/wechat/...`) calls it and awaits the real result, so
the app shows success / the actual `errcode` instead of the old fire-and-forget
GitHub-Action dispatch.

- **Dumb relay:** holds no R2 / `FILES_TOKEN`. For publishing it gets either a ready
  `access_token/authorizer_appid` (preferred) or legacy `appid/secret` + the article
  per request (in memory, never logged), talks to WeChat, returns the mutated article
  (with `wechatMediaId`) + final thumb id. The Function persists to R2. When both
  credential forms are present, `access_token` wins. It also provides five strict
  third-party-platform operations so component/authorizer token traffic leaves from
  this fixed IP; Cloudflare still owns expiry decisions and all R2 writes.
- **Reachable only via a Cloudflare Tunnel** (`wechat-pub.jianshuo.dev` →
  `127.0.0.1:8848`). No open inbound port. Every request needs
  `X-Relay-Secret: $WECHAT_RELAY_SECRET` (constant-time check).
- **Self-contained** `relay_server.py` (stdlib only) — the WeChat + cover helpers it
  once `import`ed from `mine.py` are now inlined; `mine.py` is gone. `tinyproxy` on
  this box is unrelated and stays as-is.

## Internal API

Every POST requires `X-Relay-Secret` and JSON. Paths and fields are allowlisted;
there is no arbitrary URL proxy.

| Path | Required JSON fields |
|---|---|
| `/component-token` | `component_appid`, `component_appsecret`, `component_verify_ticket` |
| `/pre-auth-code` | `component_access_token`, `component_appid` |
| `/query-auth` | `component_access_token`, `component_appid`, `authorization_code` |
| `/authorizer-info` | `component_access_token`, `component_appid`, `authorizer_appid` |
| `/authorizer-token` | `component_access_token`, `component_appid`, `authorizer_appid`, `authorizer_refresh_token` |
| `/publish` | Ready `access_token` + `authorizer_appid`, or legacy `appid` + `secret`, plus the article |
| `/validate` | Legacy `appid`, `secret` |

Credentials are passed over the Cloudflare Tunnel's HTTPS connection, held only for
the request, never logged, and never persisted by the relay. The response is returned
to the Pages Function, which updates `config/wechat-component.json` or the user's
`WECHAT.json` in R2.

## First-time setup

From the dev box (repo root):

```bash
VPS_SSH=root@66.42.45.128 ./mining/deploy_relay.sh   # copies code to /opt/wechat-relay
```

Then on the VPS (one-time):

```bash
WECHAT_RELAY_SECRET=<paste the same value you set in Cloudflare Pages> \
  bash /opt/wechat-relay/provision.sh
```

`provision.sh` installs+starts the `wechat-relay` systemd unit and prints the
remaining `cloudflared` tunnel steps (install → login → create → route dns → config →
service install). The shared secret in `/opt/wechat-relay/relay.env` MUST equal the
Cloudflare Pages secret `WECHAT_RELAY_SECRET`.

## Updating the code later

```bash
VPS_SSH=root@66.42.45.128 ./mining/deploy_relay.sh   # rsync + restart + health check
```

## Health / debugging

```bash
curl https://wechat-pub.jianshuo.dev/health     # {"ok":true}
ssh root@66.42.45.128 'systemctl status wechat-relay; journalctl -u wechat-relay -n 50'
```
