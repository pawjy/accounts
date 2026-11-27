# OAuthログインをアプリに引き継ぐ

システムの認証画面で確認したアカウントに対し、アプリのWebViewで使う通常セッションを発行する。すべてのAPIはサーバー間のBearer認証を必要とする。

## 設定とセッションの役割

`handoff_clients` に、クライアントごとの固定のHTTPS復帰先、OAuthプロバイダー、規約バージョン、セッションの用途を登録する。

```json
{"handoff_clients":{"mobile":{
  "source_context":"web-login",
  "target_context":"web",
  "redirect_uri":"https://app.example.test/account/app/return",
  "terms_version":2,
  "providers":["google"]
}}}
```

| 用途 | context | 有効期間と権限 |
| --- | --- | --- |
| 通常ブラウザ | 既存の通常context（例 `web`） | 既存のWebセッション |
| アプリ向けの本人確認 | `web-login` | 最長10分。セッション取得、登録したOAuthの開始・コールバック・アカウント選択、対象規約への同意、コード発行に限定 |
| 交換後のアプリ | 通常ブラウザと同じcontext | 通常の有効期間。新しいセッションIDと独立したキーを発行 |

有効なクライアントがあると `web-login` が認証専用になる。この名前を既存の通常contextに使っている環境では事前に用途の重複を解消する。targetには既存アプリの通常contextを指定し、認証用・コード保存用のcontextとは区別する。クライアント側Webサーバーは認証専用Cookieを通常Cookieと別名で管理する。

## リクエスト

1. `/session` で `web-login` の新しいセッションを取得する。既存の `/login` に `handoff_client`、`handoff_state`（32〜128文字）、`handoff_challenge`（S256、43文字）を渡す。ログイン応答の `callback_state` はOAuthのstateで、ブラウザから共通のコールバックへ戻った際に認証用Cookieを選ぶために使える。コールバックのstateは従来どおりAccountsが照合する。
2. OAuthのコールバックと必要なアカウント選択が完了すると、認証方式・サービスと認証時刻が保留情報に結び付く。アプリ側の復帰照合に使う `handoff_state` はOAuthのstateとは別に保持する。
3. `/session/handoff/issue` に元の `sk`、`sk_context`、`client_info` をPOSTする。`client_info` はアプリの分類用のJSONオブジェクト（最大1024バイト）。例は `{"application":"mobile","platform":"ios"}`。サーバー側で分類情報だけを組み立て、Cookie・コード・認証情報を含めない。OAuth済みで規約同意だけが不足する場合は400と `needs_agreement` が返る。利用者の同意を受けてから `/agree` を呼び、発行を再試行する。
4. 発行が成功すると `code`、`state`、`redirect_uri` が返る。保留情報を行ロック下で一度だけ消費し、認証用セッションからプロバイダーの一時情報を取り除く。コードはハッシュ化して保存し、有効期間は60秒以内、かつ元セッションの期限までとする。
5. 復帰を受けたアプリはstateを照合する。サーバーが `/session/handoff/redeem` に `client_id`、`code`、`code_verifier`、元の `sk_context` をPOSTする。S256の照合は必須。Accountsは元セッション・アカウント・規約を再確認し、通常セッション作成、履歴記録、コード削除を一つのトランザクションで確定する。応答の `sk`、`sk_expires` を使ってクライアント側Webサーバーがアプリ用Cookieを設定する。

監査履歴の `data` に `source_operation`、`login_method`、`service_name`、元の公開識別子 `source_session_id`、`client_info` を記録する。セッションキー・コード・verifierはこの情報に含めない。交換済みの通常セッションは独立して失効する。交換応答を受信できず結果が不明な場合は、新しくログインを開始する。

## テスト

`./prove t/http/session-handoff.t` で、既存のOAuthテストサーバーによる一連のログインと、隔離したMariaDBを用いるHTTP・DB結合テストを実行する。後者では発行と交換の競合、期限・失効、コンテキスト分離、監査ログの書き込み失敗と再試行を検証する。Python 3とmysqlまたはmariadbクライアントを使用する。
