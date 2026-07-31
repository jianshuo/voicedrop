"""WeChat relay publish credential-mode regression tests.

Run with the same Python version as the VPS service:
  python3.12 mining/test_relay_publish.py
"""
import sys
import json
import unittest
from unittest.mock import patch

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import relay_server


class PublishCredentialsTest(unittest.TestCase):
    @patch.object(relay_server, "wechat_access_token", return_value="legacy-token")
    def test_legacy_credentials_exchange_for_access_token(self, exchange):
        token, account_appid = relay_server._resolve_publish_token({
            "appid": " wx-legacy ",
            "secret": " legacy-secret ",
        })

        self.assertEqual(token, "legacy-token")
        self.assertEqual(account_appid, "wx-legacy")
        exchange.assert_called_once_with("wx-legacy", "legacy-secret")

    @patch.object(relay_server, "wechat_access_token")
    def test_supplied_access_token_wins_when_both_modes_exist(self, exchange):
        token, account_appid = relay_server._resolve_publish_token({
            "access_token": " authorizer-token ",
            "authorizer_appid": " wx-authorizer ",
            "appid": "wx-legacy",
            "secret": "legacy-secret",
        })

        self.assertEqual(token, "authorizer-token")
        self.assertEqual(account_appid, "wx-authorizer")
        exchange.assert_not_called()

    def test_authorizer_appid_without_access_token_does_not_fall_back(self):
        with self.assertRaisesRegex(ValueError, "missing access_token"):
            relay_server._resolve_publish_token({
                "authorizer_appid": "wx-authorizer",
                "appid": "wx-legacy",
                "secret": "legacy-secret",
            })

    @patch.object(relay_server, "sync_wechat_drafts", return_value=(1, 0))
    @patch.object(relay_server, "make_photo_resolver", return_value=lambda _key: None)
    @patch.object(relay_server, "make_cover_resolver", return_value=lambda _article, force=False: "cover")
    @patch.object(relay_server, "wechat_access_token")
    def test_authorizer_appid_scopes_image_cache(
            self, exchange, _cover_resolver, photo_resolver, _sync):
        result = relay_server._publish({
            "access_token": "authorizer-token",
            "authorizer_appid": "wx-authorizer",
            "appid": "wx-legacy",
            "secret": "legacy-secret",
            "owner": "users/u/",
            "article": {
                "id": "doc-1",
                "articles": [{"title": "标题", "body": "正文"}],
            },
        })

        self.assertTrue(result["ok"])
        exchange.assert_not_called()
        photo_resolver.assert_called_once_with(
            "authorizer-token", "users/u/", "wx-authorizer")


class ComponentApiTest(unittest.TestCase):
    @patch.object(relay_server, "_wechat_req")
    def test_component_token_passes_platform_credentials_in_json_body(self, request):
        request.return_value = json.dumps({
            "component_access_token": "component-token",
            "expires_in": 7200,
        }).encode()

        result = relay_server._component_api("/component-token", {
            "component_appid": " component-appid ",
            "component_appsecret": " component-secret ",
            "component_verify_ticket": " verify-ticket ",
        })

        self.assertEqual(result["component_access_token"], "component-token")
        method, url = request.call_args.args[:2]
        self.assertEqual(method, "POST")
        self.assertEqual(
            url,
            "https://api.weixin.qq.com/cgi-bin/component/api_component_token",
        )
        self.assertEqual(json.loads(request.call_args.kwargs["data"]), {
            "component_appid": "component-appid",
            "component_appsecret": "component-secret",
            "component_verify_ticket": "verify-ticket",
        })

    @patch.object(relay_server, "_wechat_req", return_value=b'{"ok":true}')
    def test_each_token_based_operation_has_a_fixed_url_and_minimal_body(self, request):
        cases = [
            (
                "/pre-auth-code",
                {"component_access_token": "token/with space", "component_appid": "component"},
                "api_create_preauthcode",
                {"component_appid": "component"},
            ),
            (
                "/query-auth",
                {
                    "component_access_token": "token/with space",
                    "component_appid": "component",
                    "authorization_code": "auth-code",
                },
                "api_query_auth",
                {"component_appid": "component", "authorization_code": "auth-code"},
            ),
            (
                "/authorizer-info",
                {
                    "component_access_token": "token/with space",
                    "component_appid": "component",
                    "authorizer_appid": "authorizer",
                },
                "api_get_authorizer_info",
                {"component_appid": "component", "authorizer_appid": "authorizer"},
            ),
            (
                "/authorizer-token",
                {
                    "component_access_token": "token/with space",
                    "component_appid": "component",
                    "authorizer_appid": "authorizer",
                    "authorizer_refresh_token": "refresh-token",
                },
                "api_authorizer_token",
                {
                    "component_appid": "component",
                    "authorizer_appid": "authorizer",
                    "authorizer_refresh_token": "refresh-token",
                },
            ),
        ]

        for path, payload, endpoint, expected_body in cases:
            with self.subTest(path=path):
                request.reset_mock()
                relay_server._component_api(path, payload)
                _, url = request.call_args.args[:2]
                self.assertEqual(
                    url,
                    "https://api.weixin.qq.com/cgi-bin/component/"
                    + endpoint
                    + "?component_access_token=token%2Fwith%20space",
                )
                self.assertEqual(
                    json.loads(request.call_args.kwargs["data"]),
                    expected_body,
                )

    @patch.object(relay_server, "_wechat_req")
    def test_missing_credentials_are_rejected_before_network(self, request):
        with self.assertRaisesRegex(ValueError, "missing component_appsecret"):
            relay_server._component_api("/component-token", {
                "component_appid": "component",
                "component_verify_ticket": "ticket",
            })
        request.assert_not_called()

    def test_arbitrary_component_operation_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "unsupported component operation"):
            relay_server._component_api("/proxy-any-url", {
                "url": "https://example.com/",
            })


if __name__ == "__main__":
    unittest.main(verbosity=2)
