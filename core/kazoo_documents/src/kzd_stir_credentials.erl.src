%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `stir_credentials' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_stir_credentials).

-export([new/0]).
-export([acme_eab_hmac/1, acme_eab_hmac/2, set_acme_eab_hmac/2]).
-export([acme_eab_kid/1, acme_eab_kid/2, set_acme_eab_kid/2]).
-export([stipa_password/1, stipa_password/2, set_stipa_password/2]).
-export([stipa_user/1, stipa_user/2, set_stipa_user/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"stir_credentials">>).

-spec new() -> doc().
new() ->
    kz_json_schema:default_object(?SCHEMA).

-spec acme_eab_hmac(doc()) -> any().
acme_eab_hmac(Doc) ->
    acme_eab_hmac(Doc, 'undefined').

-spec acme_eab_hmac(doc(), Default) -> any() | Default.
acme_eab_hmac(Doc, Default) ->
    kz_json:get_value([<<"acme_eab_hmac">>], Doc, Default).

-spec set_acme_eab_hmac(doc(), any()) -> doc().
set_acme_eab_hmac(Doc, AcmeEabHmac) ->
    kz_json:set_value([<<"acme_eab_hmac">>], AcmeEabHmac, Doc).

-spec acme_eab_kid(doc()) -> any().
acme_eab_kid(Doc) ->
    acme_eab_kid(Doc, 'undefined').

-spec acme_eab_kid(doc(), Default) -> any() | Default.
acme_eab_kid(Doc, Default) ->
    kz_json:get_value([<<"acme_eab_kid">>], Doc, Default).

-spec set_acme_eab_kid(doc(), any()) -> doc().
set_acme_eab_kid(Doc, AcmeEabKid) ->
    kz_json:set_value([<<"acme_eab_kid">>], AcmeEabKid, Doc).

-spec stipa_password(doc()) -> any().
stipa_password(Doc) ->
    stipa_password(Doc, 'undefined').

-spec stipa_password(doc(), Default) -> any() | Default.
stipa_password(Doc, Default) ->
    kz_json:get_value([<<"stipa_password">>], Doc, Default).

-spec set_stipa_password(doc(), any()) -> doc().
set_stipa_password(Doc, StipaPassword) ->
    kz_json:set_value([<<"stipa_password">>], StipaPassword, Doc).

-spec stipa_user(doc()) -> any().
stipa_user(Doc) ->
    stipa_user(Doc, 'undefined').

-spec stipa_user(doc(), Default) -> any() | Default.
stipa_user(Doc, Default) ->
    kz_json:get_value([<<"stipa_user">>], Doc, Default).

-spec set_stipa_user(doc(), any()) -> doc().
set_stipa_user(Doc, StipaUser) ->
    kz_json:set_value([<<"stipa_user">>], StipaUser, Doc).
