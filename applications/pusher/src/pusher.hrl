-ifndef(PUSHER_HRL).

%% Typical includes needed
-include_lib("kazoo_stdlib/include/kz_types.hrl").
-include_lib("kazoo_stdlib/include/kz_log.hrl").
-include_lib("kazoo_stdlib/include/kz_databases.hrl").

-define(APP_NAME, <<"pusher">>).
-define(APP_VERSION, <<"4.0.0">>).
-define(CONFIG_CAT, ?APP_NAME).

-define(DEFAULT_APNS_HOST, <<"api.push.apple.com">>).
-define(TOKEN_KEY, <<"Token-ID">>).
-define(TOKEN_PROXY_KEY, <<"Proxy-Path">>).
-define(TOKEN_PUBLIC_PROXY_KEY, <<"Proxy-URI">>).

-define(TOKEN_TYPE_APPLE, <<"apple">>).
-define(TOKEN_TYPE_FIREBASE, <<"firebase">>).
-define(TOKEN_TYPE_FIREBASE_V1, <<"firebase_v1">>).
%% Token types with a gen_server pusher module started by pusher_module_sup
-define(TOKEN_MOD_TYPES, [?TOKEN_TYPE_APPLE, ?TOKEN_TYPE_FIREBASE]).
%% system_config/pusher object mapping further token types to push modules
%% (pusher_module behaviour) that live outside this application
-define(TOKEN_TYPE_MODULES_KEY, <<"token_type_modules">>).

-define(KEY_TIMESTAMP_MS, <<"Timestamp-MS">>).

-type push_app_id() :: kz_term:ne_binary().
-type push_app() :: {kz_term:api_pid(), map()}.
-type token_type() :: kz_term:ne_binary().

-define(AUTH_TYPE_CERT, 'certdata').
-define(AUTH_TYPE_TOKEN, 'token').

-define(APNS_AUTH_KEY_PEM, <<"private_key.p8">>).

-define(PUSH_TYPE_VOIP, <<"voip">>).
-define(PUSH_TYPE_ALERT, <<"alert">>).

-define(PUSHER_HRL, 'true').
-endif.
